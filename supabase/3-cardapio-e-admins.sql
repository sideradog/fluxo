-- Fluxo: cardapio no banco, eventos novos e administrador maximo.
-- Rodar uma vez no SQL Editor do Supabase.

-- 1. Administrador maximo (pode dar e tirar admin)
alter table public.perfis add column if not exists super boolean not null default false;

create or replace function public.eh_super() returns boolean
language sql stable security definer set search_path = public
as $$ select coalesce((select super from public.perfis where id = auth.uid()), false) $$;

update public.perfis set super = true, admin = true where cpf = '57565415863';

-- 2. Eventos criados pelo app
alter table public.eventos add column if not exists criado_em timestamptz not null default now();

-- 3. Cardapio
create table if not exists public.produtos (
  id text primary key default gen_random_uuid()::text check (char_length(id) <= 40),
  evento_id text check (evento_id is null or char_length(evento_id) <= 40),
  nome text not null check (char_length(nome) between 1 and 60),
  descricao text not null default '' check (char_length(descricao) <= 160),
  preco numeric(10,2) not null check (preco >= 0 and preco <= 100000),
  categoria text not null default 'Bebidas' check (char_length(categoria) between 1 and 30),
  foto text check (foto is null or foto like 'img/%' or (foto like 'data:image/%' and char_length(foto) <= 300000)),
  ativo boolean not null default true,
  ordem int not null default 0,
  criado_em timestamptz not null default now()
);

alter table public.produtos enable row level security;
revoke all on public.produtos from anon, authenticated;
grant select on public.produtos to anon, authenticated;
grant insert, update, delete on public.produtos to authenticated;

drop policy if exists "produtos: todos leem" on public.produtos;
create policy "produtos: todos leem" on public.produtos for select to anon, authenticated using (true);
drop policy if exists "produtos: admin cria" on public.produtos;
create policy "produtos: admin cria" on public.produtos for insert to authenticated with check (public.eh_admin());
drop policy if exists "produtos: admin edita" on public.produtos;
create policy "produtos: admin edita" on public.produtos for update to authenticated using (public.eh_admin()) with check (public.eh_admin());
drop policy if exists "produtos: admin apaga" on public.produtos;
create policy "produtos: admin apaga" on public.produtos for delete to authenticated using (public.eh_admin());

-- Cardapio atual, para nao comecar vazio
insert into public.produtos (id, evento_id, nome, descricao, preco, categoria, foto, ordem) values
  ('b1', null, 'Antarctica Boa', 'Unidade', 10.00, 'Bebidas', 'img/antarctica.jpg', 10),
  ('b2', null, 'Skol Beats', 'Unidade', 15.00, 'Bebidas', 'img/skol-beats.jpg', 20),
  ('b3', null, 'Copão de vodka', 'Copo', 15.00, 'Bebidas', 'img/copao.jpg', 30),
  ('b4', null, 'Red Bull', 'Lata', 20.00, 'Bebidas', 'img/red-bull.jpg', 40),
  ('b5', null, 'Big Power 2 litros', 'Energético, garrafa de 2 litros', 25.00, 'Bebidas', 'img/big-power.jpg', 50),
  ('b6', null, 'Água', 'Garrafa', 5.00, 'Bebidas', 'img/agua.jpg', 60),
  ('p1', null, 'Antarctica Boa, 3 unidades', 'Promoção: 3 unidades por R$ 25,00', 25.00, 'Promoções', 'img/antarctica.jpg', 70),
  ('c1', null, 'Balde com 6 Antarctica Boa', '6 unidades no balde', 45.00, 'Combos', 'img/antarctica.jpg', 80),
  ('c2', null, 'Combo Red Label + 4 Red Bull', '1 garrafa de Red Label e 4 Red Bull', 300.00, 'Combos', 'img/combo-red-label-red-bull.jpg', 90),
  ('c3', null, 'Combo Smirnoff + 4 Red Bull', '1 garrafa de Smirnoff e 4 Red Bull', 250.00, 'Combos', 'img/combo-smirnoff-red-bull.jpg', 100),
  ('c4', null, 'Red Label + Big Power + gelo + copo', '1 garrafa de Red Label, Big Power, gelo e copo', 230.00, 'Combos', null, 110),
  ('c5', null, 'Smirnoff + Big Power + gelo + copo', '1 garrafa de Smirnoff, Big Power, gelo e copo', 180.00, 'Combos', null, 120),
  ('o1', null, 'Bistrô', 'Mesa bistrô para o seu grupo', 50.00, 'Mesas', 'img/bistro.jpg', 130)
on conflict (id) do nothing;

-- 4. Lista de administradores (so o administrador maximo ve)
create or replace function public.listar_admins()
returns table (id uuid, codigo text, nome text, super boolean)
language sql stable security definer set search_path = public
as $$
  select p.id, p.codigo, p.nome, p.super
  from public.perfis p
  where p.admin and public.eh_super()
  order by p.super desc, p.nome
$$;

-- 5. Dar ou tirar admin pelo ID do usuario (so o administrador maximo)
create or replace function public.definir_admin(p_codigo text, p_admin boolean) returns json
language plpgsql security definer set search_path = public
as $$
declare alvo public.perfis%rowtype;
begin
  if not public.eh_super() then
    return json_build_object('status', 'sem_permissao');
  end if;
  select * into alvo from public.perfis where codigo = upper(trim(p_codigo));
  if not found then
    return json_build_object('status', 'inexistente');
  end if;
  if alvo.id = auth.uid() then
    return json_build_object('status', 'proprio');
  end if;
  if alvo.super then
    return json_build_object('status', 'super');
  end if;
  update public.perfis set admin = p_admin where id = alvo.id;
  return json_build_object('status', 'ok', 'nome', alvo.nome);
end $$;

revoke all on function public.eh_super() from public, anon;
revoke all on function public.listar_admins() from public, anon;
revoke all on function public.definir_admin(text, boolean) from public, anon;
grant execute on function public.eh_super() to authenticated;
grant execute on function public.listar_admins() to authenticated;
grant execute on function public.definir_admin(text, boolean) to authenticated;
