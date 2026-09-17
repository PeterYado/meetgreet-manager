-- =============================================================================
--  ミーグリ管理 : Step 3  応募プラン(申込の下書き)
--  Supabase → SQL Editor に貼り付けて Run。何度実行しても安全(冪等)。
--
--  CDを先に注文する時点と、実際に申し込む時点がずれるため、配分の検討は
--  一度では終わらない。途中まで組んだ内容を残しておけるようにする。
--
--  単位は リリース × メンバー × 種別 × 回次。
--  個別と全国/リアルでは作業そのものが違うので種別で分ける。
--    個別      … 総枚数は規則で決まる(1部あたり×最大部数×セット数)。
--                 どの開催日のどの部に入れるかだけを決める。
--    全国/リアル … 先に買った枚数が予算。まず開催日ごとに割り振り、
--                 その中で部ごとに配分する。
--
--  配分そのものは data(jsonb)に入れる。開催日や部が後から増減しても
--  列の作り直しが要らないため。
--    {
--      "eventBudget": { "<event_id>": 50 },          -- 開催日ごとの予算
--      "cells":       { "<event_id>:<bu_no>": 12 }   -- 部ごとの配分枚数
--    }
-- =============================================================================

create table if not exists mg_plans (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  release_id uuid not null references mg_releases(id) on delete cascade,
  member_id  uuid not null references mg_members(id) on delete cascade,
  event_type text not null,
  round      integer not null check (round > 0),
  budget     integer,                                   -- 総予算(全国/リアルのみ)
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  unique (release_id, member_id, event_type, round)
);
alter table mg_plans enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies
                 where tablename='mg_plans' and policyname='mg_plans_own') then
    create policy mg_plans_own on mg_plans
      for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
  end if;
end $$;
create index if not exists mg_plans_release_idx on mg_plans(release_id, member_id);
