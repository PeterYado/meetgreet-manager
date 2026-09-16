-- =============================================================================
--  ミーグリ管理 : Step 0  スキーマ拡張
--  Supabase → SQL Editor に貼り付けて Run。何度実行しても安全(冪等)。
--
--  既存テーブルの主キー・外部キーはすべて uuid であることを確認済み。
--  この拡張が入れて可能になること:
--    - 無敵券(メンバー欠席の振替券)を抽選と分けて管理する
--    - リリース × メンバー の「完売」状態を持つ
--    - 部を指定しない応募行(過去データ移行用)を許す
--    - 全握シリアル(先払い)と個握券(後払い)の費用を記録する
--    - グループごとの週次申込サイクル(木15時開始→金14時締切→金18時発表 等)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) メンバー : 卒業フラグ
--    卒業したメンバーの無敵券は使えなくなるため、残高表示から外す判定に使う。
-- -----------------------------------------------------------------------------
alter table mg_members
  add column if not exists is_graduated boolean not null default false;


-- -----------------------------------------------------------------------------
-- 2) グループ : 週次申込サイクル等の設定
--    乃木坂と AKB でスケジュールが違うのでグループ単位で持つ。
--    config 例 (dow: 0=日 1=月 … 3=水 4=木 5=金 6=土):
--    {
--      "cycle": {
--        "lottery": { "open_dow":4, "open_time":"15:00",
--                     "close_dow":5, "close_time":"14:00",
--                     "result_dow":5,"result_time":"18:00" },
--        "comp":    { "dow":3, "scope":"same_week", "first_come":true }
--      }
--    }
--    comp(無敵券)は「開催週の水曜に、その週の開催分だけ」「先着で部が閉まる」。
-- -----------------------------------------------------------------------------
alter table mg_groups
  add column if not exists config jsonb not null default '{}'::jsonb;


-- -----------------------------------------------------------------------------
-- 3) リリース : 費用と応募ルール
--    個別と全国/リアルは支払いの向きが逆なので別々に持つ。
--      個別      … 当選した枚数だけ後から 1200円 の CD を買う
--      全国/リアル … 先に CD を買い、同梱シリアルで応募する(落選すると無駄になる)
--
--    config.applyRules 例(回次ごとの応募上限。掛け算の形だけ固定し数値は可変):
--      [ {"round":1,"perSession":3,"maxSessions":15,"sets":1},    -- = 45枚
--        {"round":2,"perSession":5,"maxSessions":15,"sets":5} ]   -- = 375枚
--    ルールは稀に変わる(2次は 3枚→5枚 に変わった実績あり)のでデータで保持する。
-- -----------------------------------------------------------------------------
alter table mg_releases
  add column if not exists zen_qty        integer,                   -- 全握券(先払いCD)枚数
  add column if not exists zen_unit_price integer,                   -- 全握券 1枚当たり
  add column if not exists zen_shipping   integer not null default 0, -- 送料
  add column if not exists koj_unit_price integer,                   -- 個握券 単価(後払い)
  add column if not exists config         jsonb not null default '{}'::jsonb;


-- -----------------------------------------------------------------------------
-- 4) 応募行 : 抽選 / 無敵券 の区別と、部未指定の許容
--    kind='comp' は無敵券。抽選を経ていないので当選率の分子・分母どちらにも
--    入れてはいけない。従来スプレッドシートで「-4」等の手動補正をしていた分。
--
--    session_id を nullable にするのは過去データ移行のため。
--    申請枚数は10年間「開催日 × 回次」単位でしか記録していないので、
--    部に按分せず「部未指定の応募行」として持つ(部別集計から自然に外れる)。
-- -----------------------------------------------------------------------------
alter table mg_applications
  add column if not exists kind     text not null default 'lottery',
  add column if not exists event_id uuid references mg_events(id) on delete cascade;

alter table mg_applications
  alter column session_id drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'mg_applications_kind_chk') then
    alter table mg_applications
      add constraint mg_applications_kind_chk check (kind in ('lottery','comp'));
  end if;

  -- 部か開催日のどちらかには必ず紐づく
  if not exists (select 1 from pg_constraint where conname = 'mg_applications_target_chk') then
    alter table mg_applications
      add constraint mg_applications_target_chk
      check (session_id is not null or event_id is not null);
  end if;

  -- 無敵券は抽選ではないので申請枚数は常に 0
  if not exists (select 1 from pg_constraint where conname = 'mg_applications_comp_chk') then
    alter table mg_applications
      add constraint mg_applications_comp_chk
      check (kind <> 'comp' or coalesce(applied,0) = 0);
  end if;
end $$;

create index if not exists mg_applications_event_idx on mg_applications(event_id);
create index if not exists mg_applications_kind_idx  on mg_applications(kind);


-- -----------------------------------------------------------------------------
-- 5) 無敵券 発行台帳
--    メンバーが欠席したときに発行され、そのメンバーにのみ使える。
--    有効期限は実質なし(卒業まで)なので expiry 列は持たない。
--    残高 = 発行合計 − 使用合計(mg_applications の kind='comp' の won 合計)
-- -----------------------------------------------------------------------------
create table if not exists mg_comp_tickets (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  member_id       uuid not null references mg_members(id) on delete cascade,
  qty             integer not null check (qty > 0),
  issued_date     date,
  source_event_id uuid references mg_events(id) on delete set null,  -- 欠席が出た開催日
  note            text,
  created_at      timestamptz not null default now()
);
alter table mg_comp_tickets enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies
                 where tablename='mg_comp_tickets' and policyname='mg_comp_tickets_own') then
    create policy mg_comp_tickets_own on mg_comp_tickets
      for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
  end if;
end $$;
create index if not exists mg_comp_tickets_member_idx on mg_comp_tickets(member_id);


-- -----------------------------------------------------------------------------
-- 6) リリース × メンバー : 完売状態
--    完売の速さはメンバーごとに違う。完売後に増える枚数は抽選由来ではないので、
--    入力時の既定を「無敵券」に寄せるヒントとして使う(自動判定はしない)。
--    sold_out_round は「何次で完売したか」= 人気度の指標にもなる。
-- -----------------------------------------------------------------------------
create table if not exists mg_release_members (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  release_id     uuid not null references mg_releases(id) on delete cascade,
  member_id      uuid not null references mg_members(id) on delete cascade,
  sold_out       boolean not null default false,
  sold_out_round integer,
  updated_at     timestamptz not null default now(),
  unique (release_id, member_id)
);
alter table mg_release_members enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies
                 where tablename='mg_release_members' and policyname='mg_release_members_own') then
    create policy mg_release_members_own on mg_release_members
      for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
  end if;
end $$;


-- -----------------------------------------------------------------------------
--  確認用: 実行後にこれを流すと、追加された列とテーブルが見える
-- -----------------------------------------------------------------------------
-- select table_name, column_name, data_type, is_nullable
-- from information_schema.columns
-- where table_name in ('mg_members','mg_groups','mg_releases','mg_applications',
--                      'mg_comp_tickets','mg_release_members')
-- order by table_name, ordinal_position;
