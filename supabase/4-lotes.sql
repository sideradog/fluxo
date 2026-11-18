-- Fluxo: lotes de ingresso. Rodar uma vez no SQL Editor do Supabase.
-- "Ultimos compradores" passa a contar todos os lotes de ingresso do evento.
create or replace function public.compradores(p_evento text)
returns table (nome text, foto text)
language sql stable security definer set search_path = public
as $$
  select split_part(p.nome, ' ', 1), p.foto
  from public.perfis p
  join (
    select usuario_id, max(criado_em) as ultima
    from public.fichas
    where evento_id = p_evento
      and (produto = 'ing-' || p_evento or produto like 'ing-' || p_evento || '.%')
    group by usuario_id
  ) c on c.usuario_id = p.id
  order by c.ultima desc
  limit 8
$$;

revoke all on function public.compradores(text) from public, anon;
grant execute on function public.compradores(text) to authenticated;
