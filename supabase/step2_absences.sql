-- =============================================================================
--  ミーグリ管理 : Step 2  欠席(部単位)の記録
--  Supabase → SQL Editor に貼り付けて Run。何度実行しても安全(冪等)。
--
--  メンバーが欠席した部を記録する。欠席しても「当選した」事実は変わらないので
--  当選率の分子にも個握券の費用にも残す。変わるのは「実際に参加できたか」だけ
--  なので、枚数はそのままにして印だけ付ける。
--
--  欠席は1日まるごととは限らない(例: 1〜3部は欠席、4・5部は参加)ため、
--  単位は 開催日ではなく 部 × メンバー。
-- =============================================================================

create table if not exists mg_absences (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  session_id     uuid not null references mg_sessions(id) on delete cascade,
  member_id      uuid not null references mg_members(id) on delete cascade,
  -- この欠席で発行された無敵券(あれば)。発行記録を消しても欠席の事実は残す。
  comp_ticket_id uuid references mg_comp_tickets(id) on delete set null,
  note           text,
  created_at     timestamptz not null default now(),
  unique (session_id, member_id)
);
alter table mg_absences enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies
                 where tablename='mg_absences' and policyname='mg_absences_own') then
    create policy mg_absences_own on mg_absences
      for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
  end if;
end $$;
create index if not exists mg_absences_member_idx on mg_absences(member_id);
create index if not exists mg_absences_session_idx on mg_absences(session_id);
