-- Fluxo: estrutura do banco de dados.
-- Rodar uma vez no SQL Editor do Supabase. Pode ser rodado de novo sem perder dados.

-- 1. Perfis (um por conta)
create table if not exists public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  codigo text not null unique,
  nome text not null check (char_length(nome) between 1 and 60),
  cpf text not null unique check (cpf ~ '^[0-9]{11}$'),
  celular text check (celular is null or char_length(celular) <= 20),
  foto text check (foto is null or (foto like 'data:image/%' and char_length(foto) <= 300000)),
  admin boolean not null default false,
  criado_em timestamptz not null default now()
);

create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select coalesce((select admin from public.perfis where id = auth.uid()), false) $$;

-- Confere os digitos verificadores do CPF
create or replace function public.cpf_valido(c text) returns boolean
language plpgsql immutable
as $$
declare s int; t int; i int;
begin
  if c is null or c !~ '^[0-9]{11}$' or c ~ '^([0-9])\1{10}$' then
    return false;
  end if;
  for t in 9..10 loop
    s := 0;
    for i in 1..t loop
      s := s + substr(c, i, 1)::int * (t + 2 - i);
    end loop;
    if (s * 10) % 11 % 10 <> substr(c, t + 1, 1)::int then
      return false;
    end if;
  end loop;
  return true;
end $$;

-- Cria o perfil automaticamente quando uma conta nova e registrada.
-- O CPF vem do cadastro, precisa ser valido e so pode existir em uma conta.
create or replace function public.novo_perfil() returns trigger
language plpgsql security definer set search_path = public
as $$
declare cod text; v_cpf text;
begin
  v_cpf := regexp_replace(coalesce(new.raw_user_meta_data->>'cpf', ''), '[^0-9]', '', 'g');
  if not public.cpf_valido(v_cpf) then
    raise exception 'CPF invalido';
  end if;
  if exists (select 1 from public.perfis where cpf = v_cpf) then
    raise exception 'CPF ja cadastrado';
  end if;
  loop
    cod := 'U-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from public.perfis where codigo = cod);
  end loop;
  insert into public.perfis (id, codigo, nome, cpf, celular)
  values (
    new.id,
    cod,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'nome'), ''), 'Sem nome'), 60),
    v_cpf,
    left(new.raw_user_meta_data->>'celular', 20)
  );
  return new;
end $$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
for each row execute function public.novo_perfil();

-- 2. Edicoes dos eventos feitas pelo admin
create table if not exists public.eventos (
  id text primary key check (char_length(id) <= 40),
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);

-- 3. Equipe do balcao, por evento
create table if not exists public.equipe (
  evento_id text not null check (char_length(evento_id) <= 40),
  usuario_id uuid not null references public.perfis(id) on delete cascade,
  nome text not null,
  criado_em timestamptz not null default now(),
  primary key (evento_id, usuario_id)
);

-- 4. Fichas e ingressos comprados
create table if not exists public.fichas (
  codigo text primary key check (codigo ~ '^FLX-[A-Z0-9]{4}-[A-Z0-9]{4}$'),
  usuario_id uuid not null default auth.uid() references public.perfis(id) on delete cascade,
  produto text not null check (char_length(produto) <= 40),
  evento_id text not null check (char_length(evento_id) <= 40),
  usada boolean not null default false,
  usada_em timestamptz,
  validada_por uuid references public.perfis(id) on delete set null,
  criado_em timestamptz not null default now()
);
create index if not exists fichas_usuario on public.fichas (usuario_id, criado_em desc);
create index if not exists fichas_evento_produto on public.fichas (evento_id, produto);

-- 5. Permissoes
alter table public.perfis enable row level security;
alter table public.eventos enable row level security;
alter table public.equipe enable row level security;
alter table public.fichas enable row level security;

revoke all on public.perfis, public.eventos, public.equipe, public.fichas from anon, authenticated;
grant select on public.perfis to authenticated;
grant update (nome, celular, foto) on public.perfis to authenticated;
grant select on public.eventos to anon, authenticated;
grant insert, update, delete on public.eventos to authenticated;
grant select, insert, delete on public.equipe to authenticated;
grant select on public.fichas to authenticated;
grant insert (codigo, produto, evento_id) on public.fichas to authenticated;

drop policy if exists "perfis: ver o proprio ou admin" on public.perfis;
create policy "perfis: ver o proprio ou admin" on public.perfis for select to authenticated using (id = auth.uid() or public.eh_admin());
drop policy if exists "perfis: editar o proprio" on public.perfis;
create policy "perfis: editar o proprio" on public.perfis for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists "eventos: todos leem" on public.eventos;
create policy "eventos: todos leem" on public.eventos for select to anon, authenticated using (true);
drop policy if exists "eventos: admin cria" on public.eventos;
create policy "eventos: admin cria" on public.eventos for insert to authenticated with check (public.eh_admin());
drop policy if exists "eventos: admin edita" on public.eventos;
create policy "eventos: admin edita" on public.eventos for update to authenticated using (public.eh_admin()) with check (public.eh_admin());
drop policy if exists "eventos: admin apaga" on public.eventos;
create policy "eventos: admin apaga" on public.eventos for delete to authenticated using (public.eh_admin());
drop policy if exists "equipe: ver a propria ou admin" on public.equipe;
create policy "equipe: ver a propria ou admin" on public.equipe for select to authenticated using (usuario_id = auth.uid() or public.eh_admin());
drop policy if exists "equipe: admin adiciona" on public.equipe;
create policy "equipe: admin adiciona" on public.equipe for insert to authenticated with check (public.eh_admin());
drop policy if exists "equipe: admin remove" on public.equipe;
create policy "equipe: admin remove" on public.equipe for delete to authenticated using (public.eh_admin());
drop policy if exists "fichas: ver as proprias ou admin" on public.fichas;
create policy "fichas: ver as proprias ou admin" on public.fichas for select to authenticated using (usuario_id = auth.uid() or public.eh_admin());
drop policy if exists "fichas: criar as proprias" on public.fichas;
create policy "fichas: criar as proprias" on public.fichas for insert to authenticated with check (usuario_id = auth.uid());

-- 6. Validacao no balcao: so equipe do evento ou admin, e cada ficha vale uma vez
create or replace function public.validar_ficha(p_codigo text, p_evento text) returns json
language plpgsql security definer set search_path = public
as $$
declare f public.fichas%rowtype;
begin
  if auth.uid() is null or not (public.eh_admin() or exists (
      select 1 from public.equipe where evento_id = p_evento and usuario_id = auth.uid())) then
    return json_build_object('status', 'sem_acesso');
  end if;
  select * into f from public.fichas where codigo = upper(trim(p_codigo)) for update;
  if not found then
    return json_build_object('status', 'inexistente');
  end if;
  if f.evento_id <> p_evento then
    return json_build_object('status', 'outro', 'evento', f.evento_id, 'produto', f.produto);
  end if;
  if f.usada then
    return json_build_object('status', 'usada', 'produto', f.produto, 'usada_em', f.usada_em);
  end if;
  update public.fichas set usada = true, usada_em = now(), validada_por = auth.uid() where codigo = f.codigo;
  return json_build_object('status', 'ok', 'produto', f.produto);
end $$;

-- 7. Admin busca uma pessoa pelo ID (U-XXXXXXXX) para colocar na equipe
create or replace function public.buscar_usuario(p_codigo text) returns json
language plpgsql stable security definer set search_path = public
as $$
declare r json;
begin
  if not public.eh_admin() then
    return null;
  end if;
  select json_build_object('id', id, 'nome', nome, 'codigo', codigo) into r
  from public.perfis where codigo = upper(trim(p_codigo));
  return r;
end $$;

-- 8. Ultimos compradores de ingresso de um evento (primeiro nome e foto)
create or replace function public.compradores(p_evento text)
returns table (nome text, foto text)
language sql stable security definer set search_path = public
as $$
  select split_part(p.nome, ' ', 1), p.foto
  from public.perfis p
  join (
    select usuario_id, max(criado_em) as ultima
    from public.fichas
    where evento_id = p_evento and produto = 'ing-' || p_evento
    group by usuario_id
  ) c on c.usuario_id = p.id
  order by c.ultima desc
  limit 8
$$;

revoke all on function public.novo_perfil() from public, anon, authenticated;
revoke all on function public.eh_admin() from public, anon;
revoke all on function public.validar_ficha(text, text) from public, anon;
revoke all on function public.buscar_usuario(text) from public, anon;
revoke all on function public.compradores(text) from public, anon;
grant execute on function public.eh_admin() to authenticated;
grant execute on function public.validar_ficha(text, text) to authenticated;
grant execute on function public.buscar_usuario(text) to authenticated;
grant execute on function public.compradores(text) to authenticated;
