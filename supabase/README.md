# Supabase スキーマ

## step0_extend.sql

無敵券・完売状態・当選/申請上限・費用・週次申込サイクルを扱えるようにする拡張。
Supabase ダッシュボード → **SQL Editor** → New query に貼り付けて **Run**。

何度実行しても安全(冪等)。2回目以降は `already exists, skipping` の NOTICE が
出るだけで、データは変更されない。

### 入るもの

| 対象 | 追加 | 用途 |
|---|---|---|
| `mg_members` | `is_graduated` | 卒業したメンバーの無敵券を残高表示から外す |
| `mg_groups` | `config` (jsonb) | 週次申込サイクル(木15時開始→金14時締切→金18時発表 / 水=無敵券) |
| `mg_releases` | `zen_qty` `zen_unit_price` `zen_shipping` `koj_unit_price` | 全握券(先払い)と個握券(後払い)の費用 |
| `mg_releases` | `config` (jsonb) | 回次ごとの応募上限ルール(`applyRules`) |
| `mg_applications` | `kind` (`lottery`/`comp`) | 無敵券を抽選と分離。当選率・費用の集計から除外する |
| `mg_applications` | `event_id` + `session_id` を nullable 化 | 部を指定しない応募行(過去データ移行用) |
| `mg_comp_tickets` | 新規テーブル | 無敵券の発行台帳。残高は発行合計 − 使用合計で算出 |
| `mg_release_members` | 新規テーブル | リリース × メンバー の完売状態と完売回次 |

### 制約

- `kind` は `lottery` か `comp` のみ
- `kind='comp'` の行は `applied` が必ず 0(抽選を経ていないため)
- `session_id` と `event_id` のどちらかは必ず埋まっている

### 検証済み

PostgreSQL 16 にスタブスキーマを作って実行し、次を確認済み。

- 初回実行・2回目実行ともエラーなし(冪等)
- 抽選行 / 無敵券行 / 部未指定行 の挿入が通る
- `kind='comp'` で `applied>0`、部も開催日も無い行、未知の `kind` は拒否される
- 無敵券の残高が「発行 − 使用」で正しく出る
- 当選率の集計から `kind='comp'` が除外される
- 開催日を削除すると部未指定の応募行も cascade で消える

## ベーススキーマについて

`mg_groups` / `mg_members` / `mg_releases` / `mg_events` / `mg_sessions` /
`mg_applications` / `mg_app_settings` の初期 DDL はこのリポジトリに入っていない
(Supabase コンソール側にのみ存在する)。復旧用に、いずれ現行スキーマの
ダンプもここに置いておきたい。
