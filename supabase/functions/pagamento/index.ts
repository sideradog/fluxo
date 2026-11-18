// Fluxo: função de pagamento (Asaas)
// Cria cobranças Pix e cartão, confere o status e libera as fichas.
// Segredo necessário: ASAAS_API_KEY. Opcional: ASAAS_URL (padrão: sandbox).
import { createClient } from "jsr:@supabase/supabase-js@2";

const ASAAS_URL = Deno.env.get("ASAAS_URL") || "https://api-sandbox.asaas.com/v3";
const ASAAS_KEY = Deno.env.get("ASAAS_API_KEY") || "";
const SANDBOX = ASAAS_URL.includes("sandbox");

// Preço padrão do ingresso de eventos que ainda não foram editados no app
const EVENTOS_PADRAO: Record<string, { lotes: Lote[] }> = {
  e3: { lotes: [{ id: "", nome: "Lote promocional", preco: 25, status: "venda" }] },
};

type Lote = { id: string; nome: string; preco: number; status: string };

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function resp(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

async function asaas(path: string, method = "GET", body?: unknown) {
  const r = await fetch(ASAAS_URL + path, {
    method,
    headers: { "Content-Type": "application/json", "User-Agent": "fluxo", access_token: ASAAS_KEY },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const msg = (j.errors && j.errors[0] && j.errors[0].description) || "Erro no Asaas (" + r.status + ")";
    throw new Error(msg);
  }
  return j;
}

const PAGO = ["RECEIVED", "CONFIRMED", "RECEIVED_IN_CASH"];
const FALHOU = ["REFUNDED", "CHARGEBACK_REQUESTED", "CHARGEBACK_DISPUTE", "AWAITING_CHARGEBACK_REVERSAL", "REFUND_REQUESTED"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (!ASAAS_KEY) return resp({ erro: "Chave do Asaas não configurada no Supabase." }, 500);
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // Aviso automático do Asaas (webhook)
    const whToken = req.headers.get("asaas-access-token");
    if (whToken !== null) {
      const esperado = Deno.env.get("ASAAS_WEBHOOK_TOKEN") || "";
      if (!esperado || whToken !== esperado) return resp({ erro: "Token inválido." }, 401);
      const ev = await req.json().catch(() => ({}));
      const payId = ev?.payment?.id;
      if (payId) {
        const { data: p } = await admin.from("pedidos").select("id,status").eq("asaas_id", payId).maybeSingle();
        if (p && p.status === "pendente") {
          // Confere direto no Asaas antes de liberar, sem confiar só no aviso
          const pay = await asaas("/payments/" + payId);
          if (PAGO.includes(pay.status)) await admin.rpc("liberar_pedido", { p_pedido: p.id });
          else if (FALHOU.includes(pay.status) || pay.deleted) await admin.from("pedidos").update({ status: "falhou" }).eq("id", p.id).eq("status", "pendente");
        }
      }
      return resp({ ok: true });
    }

    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: ud, error: ue } = await admin.auth.getUser(token);
    if (ue || !ud.user) return resp({ erro: "Entre na sua conta de novo." }, 401);
    const user = ud.user;
    const b = await req.json().catch(() => ({}));

    // Confere pedidos pendentes e libera os pagos
    async function conferir(ids: string[]) {
      const { data: peds } = await admin.from("pedidos").select("*").eq("usuario_id", user.id).eq("status", "pendente").in("id", ids);
      const out: Record<string, string> = {};
      for (const p of peds || []) {
        if (!p.asaas_id) continue;
        const pay = await asaas("/payments/" + p.asaas_id);
        if (PAGO.includes(pay.status)) {
          await admin.rpc("liberar_pedido", { p_pedido: p.id });
          out[p.id] = "pago";
        } else if (FALHOU.includes(pay.status) || pay.deleted) {
          await admin.from("pedidos").update({ status: "falhou" }).eq("id", p.id).eq("status", "pendente");
          out[p.id] = "falhou";
        } else out[p.id] = "pendente";
      }
      return out;
    }

    if (b.acao === "status") {
      let ids: string[] = Array.isArray(b.ids) ? b.ids.slice(0, 20) : [];
      if (!ids.length) {
        const desde = new Date(Date.now() - 2 * 86400000).toISOString();
        const { data } = await admin.from("pedidos").select("id").eq("usuario_id", user.id).eq("status", "pendente").gte("criado_em", desde).limit(20);
        ids = (data || []).map((x) => x.id);
      }
      return resp({ status: ids.length ? await conferir(ids) : {} });
    }

    if (b.acao === "simular") {
      if (!SANDBOX) return resp({ erro: "Só disponível no modo de testes." }, 400);
      const { data: p } = await admin.from("pedidos").select("*").eq("id", b.id).eq("usuario_id", user.id).single();
      if (!p || p.status !== "pendente") return resp({ erro: "Pedido não encontrado." }, 404);
      await asaas("/payments/" + p.asaas_id + "/receiveInCash", "POST", {
        paymentDate: new Date().toISOString().slice(0, 10), value: Number(p.total), notifyCustomer: false,
      });
      return resp({ status: await conferir([p.id]) });
    }

    if (b.acao !== "criar") return resp({ erro: "Ação inválida." }, 400);

    // 1. Monta o pedido com os preços do banco (nunca do aparelho)
    const metodo = b.metodo === "cartao" ? "cartao" : "pix";
    const eventoAtual = String(b.evento || "").slice(0, 40);
    const carrinho: Record<string, number> = b.itens || {};
    const ids = Object.keys(carrinho).slice(0, 50);
    if (!ids.length) return resp({ erro: "Pedido vazio." }, 400);

    const prodIds = ids.filter((i) => !i.startsWith("ing-"));
    const { data: prods } = prodIds.length
      ? await admin.from("produtos").select("id,nome,preco,evento_id,ativo").in("id", prodIds)
      : { data: [] as any[] };
    const evIds = [...new Set(ids.filter((i) => i.startsWith("ing-")).map((i) => i.slice(4).split(".")[0]))];
    const { data: evs } = evIds.length
      ? await admin.from("eventos").select("id,dados").in("id", evIds)
      : { data: [] as any[] };

    const itens: { produto: string; nome: string; qtd: number; preco: number; evento: string }[] = [];
    for (const id of ids) {
      const qtd = Math.floor(Number(carrinho[id]));
      if (!(qtd >= 1 && qtd <= 50)) return resp({ erro: "Quantidade inválida." }, 400);
      if (id.startsWith("ing-")) {
        const [evId, loteId = ""] = id.slice(4).split(".");
        const dados = (evs || []).find((e) => e.id === evId)?.dados || {};
        if (dados.oculto) return resp({ erro: "Este evento não está à venda." }, 400);
        let lotes: Lote[] = dados.lotes && dados.lotes.length ? dados.lotes : (EVENTOS_PADRAO[evId]?.lotes || []);
        if (!dados.lotes?.length && Number(dados.preco) > 0) lotes = [{ id: "", nome: dados.lote || "Ingresso", preco: Number(dados.preco), status: "venda" }];
        const lote = lotes.find((l) => (l.id || "") === loteId);
        if (!lote || lote.status !== "venda" || !(Number(lote.preco) > 0)) return resp({ erro: "Esse lote de ingresso não está à venda." }, 400);
        itens.push({ produto: id, nome: "Ingresso " + (lote.nome || ""), qtd, preco: Number(lote.preco), evento: evId });
      } else {
        const p = (prods || []).find((x) => x.id === id);
        if (!p || p.ativo === false) return resp({ erro: "Um item do pedido não está mais disponível." }, 400);
        if (p.evento_id && p.evento_id !== eventoAtual) return resp({ erro: "Item de outro evento no pedido." }, 400);
        if (!eventoAtual) return resp({ erro: "Escolha o evento." }, 400);
        itens.push({ produto: id, nome: p.nome, qtd, preco: Number(p.preco), evento: eventoAtual });
      }
    }
    const total = Math.round(itens.reduce((s, i) => s + i.qtd * i.preco, 0) * 100) / 100;
    if (!(total >= 5)) return resp({ erro: "O valor mínimo do pedido é R$ 5,00." }, 400);

    // 2. Cliente no Asaas
    const { data: perfil } = await admin.from("perfis").select("nome,cpf,celular,asaas_cliente").eq("id", user.id).single();
    if (!perfil) return resp({ erro: "Perfil não encontrado." }, 400);
    let cliente = perfil.asaas_cliente;
    if (!cliente) {
      const c = await asaas("/customers", "POST", {
        name: perfil.nome, cpfCnpj: perfil.cpf, email: user.email,
        mobilePhone: (perfil.celular || "").replace(/\D/g, "") || undefined,
        externalReference: user.id, notificationDisabled: true,
      });
      cliente = c.id;
      await admin.from("perfis").update({ asaas_cliente: cliente }).eq("id", user.id);
    }

    // 3. Pedido no banco
    const { data: ped, error: pe } = await admin.from("pedidos")
      .insert({ usuario_id: user.id, itens, total, metodo }).select("id").single();
    if (pe || !ped) throw new Error("Não foi possível registrar o pedido.");

    // 4. Cobrança
    const hoje = new Date(Date.now() - 3 * 3600000).toISOString().slice(0, 10);
    const base = {
      customer: cliente, value: total, dueDate: hoje, externalReference: ped.id,
      description: "Fluxo: " + itens.map((i) => i.qtd + "x " + i.nome).join(", ").slice(0, 400),
    };
    try {
      if (metodo === "pix") {
        const pay = await asaas("/payments", "POST", { ...base, billingType: "PIX" });
        const qr = await asaas("/payments/" + pay.id + "/pixQrCode");
        await admin.from("pedidos").update({ asaas_id: pay.id, pix_payload: qr.payload, pix_imagem: qr.encodedImage }).eq("id", ped.id);
        return resp({ id: ped.id, total, status: "pendente", pix: { payload: qr.payload, imagem: qr.encodedImage }, sandbox: SANDBOX });
      }
      const c = b.cartao || {};
      const [mes, ano] = String(c.validade || "").split("/");
      const pay = await asaas("/payments", "POST", {
        ...base, billingType: "CREDIT_CARD",
        creditCard: {
          holderName: String(c.nome || "").slice(0, 60), number: String(c.numero || "").replace(/\D/g, ""),
          expiryMonth: (mes || "").trim(), expiryYear: "20" + (ano || "").trim().slice(-2), ccv: String(c.cvv || "").replace(/\D/g, ""),
        },
        creditCardHolderInfo: {
          name: perfil.nome, email: user.email, cpfCnpj: perfil.cpf,
          postalCode: String(c.cep || "").replace(/\D/g, ""), addressNumber: String(c.numeroEnd || "").slice(0, 10),
          mobilePhone: (perfil.celular || "").replace(/\D/g, "") || undefined,
        },
        remoteIp: (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || undefined,
      });
      await admin.from("pedidos").update({ asaas_id: pay.id }).eq("id", ped.id);
      const st = await conferir([ped.id]);
      return resp({ id: ped.id, total, status: st[ped.id] || "pendente", sandbox: SANDBOX });
    } catch (e) {
      await admin.from("pedidos").update({ status: "falhou" }).eq("id", ped.id);
      throw e;
    }
  } catch (e) {
    return resp({ erro: (e as Error).message || "Erro inesperado." }, 400);
  }
});
