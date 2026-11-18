-- Fluxo: login por e-mail. Rodar uma vez no SQL Editor do Supabase.
-- A partir daqui o CPF vem do formulario de cadastro (nao mais do e-mail interno),
-- e o banco recusa CPF invalido ou CPF que ja tenha conta.

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

revoke all on function public.novo_perfil() from public, anon, authenticated;
