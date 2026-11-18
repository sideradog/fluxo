-- Fluxo: pagamentos reais (Asaas)
-- A partir daqui, fichas só nascem depois do pagamento confirmado.

-- 1. Cliente do Asaas ligado a cada perfil
alter table public.perfis add column if not exists asaas_cliente text;

-- 2. Pedidos
create table if not exists public.pedidos (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.perfis(id) on delete cascade,
  itens jsonb not null,
  total numeric(10,2) not null check (total > 0),
  metodo text not null check (metodo in ('pix', 'cartao')),
  asaas_id text unique,
  status text not null default 'pendente' check (status in ('pendente', 'pago', 'falhou')),
  pix_payload text,
  pix_imagem text,
  criado_em timestamptz not null default now(),
  pago_em timestamptz
);
create index if not exists pedidos_usuario on public.pedidos (usuario_id, criado_em desc);

alter table public.pedidos enable row level security;
revoke all on public.pedidos from anon, authenticated;
grant select on public.pedidos to authenticated;
drop policy if exists "pedidos: ver os proprios" on public.pedidos;
create policy "pedidos: ver os proprios" on public.pedidos for select to authenticated using (usuario_id = auth.uid() or public.eh_admin());

-- 3. Clientes não criam mais fichas sozinhos
revoke insert on public.fichas from authenticated;
drop policy if exists "fichas: criar as proprias" on public.fichas;

-- 4. Libera as fichas de um pedido pago (uma vez só). Só o servidor chama.
create or replace function public.liberar_pedido(p_pedido uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  ped public.pedidos%rowtype;
  it jsonb;
  i integer;
  n integer := 0;
  cod text;
  letras text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  update public.pedidos set status = 'pago', pago_em = now()
   where id = p_pedido and status = 'pendente'
   returning * into ped;
  if not found then
    return 0;
  end if;
  for it in select * from jsonb_array_elements(ped.itens) loop
    for i in 1 .. (it->>'qtd')::int loop
      loop
        cod := 'FLX-'
          || (select string_agg(substr(letras, 1 + floor(random() * length(letras))::int, 1), '') from generate_series(1, 4))
          || '-'
          || (select string_agg(substr(letras, 1 + floor(random() * length(letras))::int, 1), '') from generate_series(1, 4));
        exit when not exists (select 1 from public.fichas where codigo = cod);
      end loop;
      insert into public.fichas (codigo, usuario_id, produto, evento_id)
      values (cod, ped.usuario_id, it->>'produto', it->>'evento');
      n := n + 1;
    end loop;
  end loop;
  return n;
end;
$$;

revoke all on function public.liberar_pedido(uuid) from public, anon, authenticated;
grant execute on function public.liberar_pedido(uuid) to service_role;
