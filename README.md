# OpenLDAP + Postfix + Dovecot 仮想メールサーバ (Docker)

OpenLDAP をユーザーディレクトリにし、Postfix の virtual mailbox / virtual
alias と Dovecot LMTP を組み合わせた、Docker Compose で動くメールサーバです。
1 ユーザーが複数のメールアドレス (`mail` 属性) を持て、どのアドレス宛でも
`/data/maildir/<uid>` の同一メールボックスに届きます。`mailForward` があれば
そちらへ転送し、Rspamd でスパム判定、certbot で STARTTLS 証明書を取得します。

- 受信: SMTP 25 (STARTTLS), Submission 587 (STARTTLS + SMTP AUTH)
- 受信/参照: IMAP 143 (STARTTLS), IMAPS 993
- 保管: `/data/maildir/<uid>` (Dovecot Maildir)
- スパム: Rspamd milter + Dovecot Sieve (Junk)
- 証明書: certbot (Let's Encrypt, HTTP-01 standalone)
- Postfix はコンテナ前提で全サービス `chroot=n`

---

## 1. 構成

```
                         ┌─────────────────────────────────────────┐
 Internet                │ Docker Compose network (172.28.0.0/16)  │
   │                     │                                         │
   ├── :25  ───────────► │ Postfix ──(milter 11332)──► Rspamd      │
   ├── :587 ───────────► │   │  │                         │        │
   │    (AUTH/TLS)       │   │  └──(LDAP)──► OpenLDAP ◄──┘        │
   │                     │   │                    ▲                │
   ├── :143/:993 ──────► │   └──(LMTP unix)──► Dovecot ──► /data   │
   │                     │                         │      /maildir │
   └── :80  ───────────► │ certbot (HTTP-01)       └── Sieve ──────┘
                         │   └── /certs (fullchain.pem, privkey.pem)
                         └─────────────────────────────────────────┘
```

| サービス | 役割 | イメージ |
|---|---|---|
| `ldap` | ユーザー、`mail`、`mailForward`、パスワード | Debian + slapd |
| `postfix` | SMTP / Submission、virtual mailbox/alias、milter | Debian + Postfix |
| `dovecot` | IMAP / LMTP、Maildir、Sieve | Debian + Dovecot |
| `rspamd` | スパム判定、DKIM 署名 | `rspamd/rspamd:4.2.3` |
| `redis` | Rspamd Bayes の統計保存 | `redis:7-alpine` |
| `certbot` | STARTTLS 証明書の取得・更新 | `certbot/certbot:v5.0.0` |

---

## 2. 要件と実装の対応

| 要件 | 実装 |
|---|---|
| 異なるメールアドレスでも 1 ユーザーの `mail` 属性に届ける | LDAP の `mail` を多値で保持。Postfix `virtual_mailbox_maps` は `(mail=%s)`、Dovecot userdb は `home=/data/maildir/%{ldap:uid}` を返す |
| virtual mailbox | `virtual_mailbox_domains` + `virtual_mailbox_maps`、実配送は Dovecot LMTP |
| virtual mail alias | `virtual_alias_maps`。`mailForward` がある場合だけ recipient を書き換える |
| 送信も `mail` 属性を元にする | ログイン名を `<uid>@<MAIL_DOMAIN>` に正規化し、`smtpd_sender_login_maps` で `mail` に含まれるアドレスだけ許可。envelope sender は `<uid>@<MAIL_DOMAIN>` に canonicalize |
| 保管先 `/data/maildir/<username>` | Dovecot の home を `/data/maildir/<uid>`、`mail_location = maildir:~/` |
| `mailForward` があれば転送 | Postfix LDAP alias map が `mailForward` を返す (ローカル保存なし) |
| Rspamd でスパム対策 | Postfix milter (11332)、スパムヘッダ付与 + Sieve で Junk、閾値以上は SMTP で reject |
| STARTTLS 用に certbot | certbot standalone (HTTP-01) + deploy hook + 証明書リロード watcher |
| Postfix は chroot 不要 | `master.cf` の全サービスで chroot 列を `n` |

---

## 3. 前提

- Docker Engine と Docker Compose v2
- グローバル IP を持つホスト、または SMTP/IMAP を公開できるネットワーク
- 次の DNS を設定できること
  - `mail.example.com` の A / AAAA レコード (このホスト)
  - `example.com` の MX レコード (`mail.example.com`)
  - 逆引き (PTR) を `mail.example.com` に設定することを推奨
- 受信ポート `25`, `587`, `143`, `993`, `80` を開放
- 外部への SMTP (25) 送信が可能であること

> このリポジトリの `example.com` / `mail.example.com` はすべてサンプルです。
> `.env` と LDIF を自分のドメインに置き換えてください。

---

## 4. クイックスタート

```bash
git clone <this-repository> ldap-mail-docker
cd ldap-mail-docker

cp .env.example .env
$EDITOR .env          # MAIL_DOMAIN, MAIL_HOSTNAME, LDAP_*, パスワードを変更

make up               # 初回は .env を作るため一度失敗します。編集後にもう一度
make ps
```

`make up` は全イメージをビルドして起動します。LDAP の初期ユーザーは
`ldap/bootstrap/bootstrap.ldif.template` の 3 人です (パスワードは
`DEMO_USER_PASSWORD` で共通)。

| uid | mail | mailForward |
|---|---|---|
| `jdoe` | `jdoe@example.com`, `john.doe@example.com`, `j.doe@example.com` | なし |
| `asmith` | `asmith@example.com`, `alice@example.com` | `jdoe@example.com` |
| `taro` | `taro@example.com`, `taro.yamada@example.com` | なし |

初回起動後に DKIM の DNS レコードを確認します。

```bash
make dkim
```

表示された TXT レコードを `mail._domainkey.example.com` に登録してください。
DNS の詳細は「6. DNS」を参照してください。

---

## 5. `.env` の設定

| 変数 | 説明 |
|---|---|
| `MAIL_DOMAIN` | メールアドレスのドメイン。Postfix の `virtual_mailbox_domains` と Rspamd の DKIM 署名ドメイン |
| `MAIL_HOSTNAME` | サーバの公開ホスト名。MX のターゲット、証明書の CN/SAN |
| `LDAP_BASE_DN` | LDAP の naming context (`dc=example,dc=com`) |
| `LDAP_ORGANISATION` | LDAP の `o` 属性 |
| `LDAP_ADMIN_PASSWORD` | `cn=admin,<LDAP_BASE_DN>` のパスワード |
| `DEMO_USER_PASSWORD` | 初期ユーザー 3 人のパスワード |
| `CERTBOT_EMAIL` | Let's Encrypt の登録メールアドレス |
| `CERTBOT_ENABLED` | `1` で取得・更新、`0` で停止 (自己署名証明書のまま) |
| `CERTBOT_STAGING` | `1` でステージング CA (本番レート制限を避ける) |
| `CERTBOT_HTTP_PORT` | certbot の HTTP-01 待受ポート。本番は `80` |
| `TZ` | タイムゾーン |

`LDAP_ADMIN_DN` は Compose が `cn=admin,${LDAP_BASE_DN}` として自動設定します。
`.env` には書きません。

---

## 6. DNS

例 (`203.0.113.10` はホストの IP):

```dns
mail.example.com.              3600 IN A    203.0.113.10
example.com.                   3600 IN MX 10 mail.example.com.

; SPF: このホストから送る場合
example.com.                   3600 IN TXT  "v=spf1 mx -all"

; DKIM: make dkim の出力
mail._domainkey.example.com.   3600 IN TXT  "v=DKIM1; k=rsa; p=MIIBIjANBg..."

; DMARC (例)
_dmarc.example.com.            3600 IN TXT  "v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com"
```

逆引き:

```dns
10.113.0.203.in-addr.arpa. 3600 IN PTR mail.example.com.
```

- 送信を別の SMTP リレー経由にする場合は SPF をそのリレーに合わせてください。
- DKIM は selector `mail`、鍵は Rspamd の `/var/lib/rspamd/dkim/<domain>.mail.key`。
  TXT レコードが長い場合、DNS プロバイダの仕様に従って 255 文字ごとに分割して
  ください (分割しても文字列は連結されます)。
- 複数ドメインを運用する場合は、`virtual_mailbox_domains` にドメインを追加し、
  各ドメインの DKIM 鍵と DNS レコードを用意してください。この構成の
  `rspamd` entrypoint は `MAIL_DOMAIN` の 1 ドメイン分だけ鍵を生成します。
- DMARC を `p=quarantine` にする前に、SPF/DKIM が通ることを確認してください。

---

## 7. LDAP データモデル

カスタムスキーマは `ldap/schema/mailaccount.schema` です。

```
dn: uid=jdoe,ou=people,dc=example,dc=com
objectClass: top
objectClass: inetOrgPerson
objectClass: mailAccount
uid: jdoe
cn: John Doe
sn: Doe
displayName: John Doe
mail: jdoe@example.com
mail: john.doe@example.com
mail: j.doe@example.com
userPassword: {SSHA}...
# mailForward: backup@example.net   # 任意・多値可
```

- `mail` は **多値**。どの値を受信しても同じ `/data/maildir/<uid>` に入ります。
- `mailForward` は任意・多値。存在する場合、そのアドレスへ転送し、ローカルには
  保存しません (コピーが必要なら別途 Sieve 等で実装)。
- `objectClass: mailAccount` が LDAP 検索の条件です。
- 同じ `mail` 値を複数ユーザーに書かないでください (配送先が曖昧になります)。
- `mail` の値は大文字小文字を区別しません (`caseIgnoreIA5Match`)。
- `<uid>@<MAIL_DOMAIN>` が `mail` に含まれるようにしてください。送信時の
  envelope sender canonicalize がこの形式を使います。

### ユーザー追加

```bash
make add-user ARGS='-u kito -n "Kito Test" \
  -m kito@example.com -m kito.alias@example.com'
```

- `-m` を省略すると `<uid>@<MAIL_DOMAIN>` になります。
- `-f` で `mailForward` を指定できます (複数可)。
- `-p` を省略するとランダムパスワードを生成して表示します。
- メールボックスディレクトリは初回配送時に Dovecot が作成します。

### 転送の設定・解除

```bash
make set-forward ARGS='kito backup@example.net'
make set-forward ARGS='kito'      # 転送を解除してローカル配送に戻す
```

直接 LDAP を編集する場合:

```bash
docker compose exec ldap ldapmodify -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=example,dc=com" -w "$LDAP_ADMIN_PASSWORD" <<'LDIF'
dn: uid=kito,ou=people,dc=example,dc=com
changetype: modify
replace: mailForward
mailForward: backup@example.net
-
LDIF
```

### 初期データの再投入

LDAP データは named volume `ldap-data` に永続化されます。LDIF を変更して
初期状態からやり直す場合は、メールデータも含めて削除されます。

```bash
docker compose down -v
docker compose up -d --build
```

---

## 8. 配送と送信の仕組み

### 8.1 受信 (recipient)

1. Postfix が `virtual_mailbox_domains` のドメイン宛を受け付けます。
2. `virtual_alias_maps` (LDAP) が `(mail=<recipient>)` を検索し、`mailForward`
   があれば recipient をその値に置き換えます。無ければそのままです。
3. `virtual_mailbox_maps` (LDAP) が `(mail=<recipient>)` で存在確認します。
4. `virtual_transport = lmtp:unix:private/dovecot-lmtp` で Dovecot LMTP に渡します。
5. Dovecot の LDAP userdb が `home=/data/maildir/<uid>` を返し、
   `mail_location = maildir:~/` で `/data/maildir/<uid>` に保存します。
6. Rspamd が `X-Spam-Flag: YES` を付けたメールは、Sieve が `Junk` に振り分けます。

Postfix のマップを手動で確認できます。

```bash
docker compose exec postfix postmap -q john.doe@example.com \
  ldap:/etc/postfix/ldap-virtual-mailbox-maps.cf
# => jdoe@example.com,john.doe@example.com,j.doe@example.com

docker compose exec postfix postmap -q asmith@example.com \
  ldap:/etc/postfix/ldap-virtual-alias-maps.cf
# => jdoe@example.com
```

### 8.2 送信 (sender)

1. ユーザーは 587 (Submission) に STARTTLS + SMTP AUTH でログインします。
   ログイン名は `mail` のどの値でも構いません。
2. Dovecot の LDAP passdb が `auth_bind` でパスワードを検証し、ユーザー名を
   `<uid>@<MAIL_DOMAIN>` に正規化します (例: `john.doe@` でログイン →
   `jdoe@example.com`)。
3. `smtpd_sender_login_maps` は送信元アドレスから `uid` と全ての `mail` 値を返します。
   `reject_sender_login_mismatch` により、認証ユーザーの `mail` に無いアドレスを
   MAIL FROM に使うと 553 で拒否されます。
4. `sender_canonical_maps` が envelope sender を `<uid>@<MAIL_DOMAIN>` に
   書き換えます (`sender_canonical_classes = envelope_sender` なので
   `From:` ヘッダは変更しません)。
5. Rspamd が認証済みメールを DKIM 署名します (`d=MAIL_DOMAIN`, `s=mail`)。
   認証ユーザー名のドメインと `From:` のドメインが一致する必要があります。

送信テスト:

```bash
# jdoe としてログインし、j.doe@ から送信 → Return-Path は jdoe@ になる
python3 - <<'PY'
import smtplib, ssl
from email.message import EmailMessage
msg = EmailMessage()
msg["From"] = "j.doe@example.com"
msg["To"] = "taro@example.com"
msg["Subject"] = "test"
msg.set_content("hello")
ctx = ssl._create_unverified_context()
with smtplib.SMTP("127.0.0.1", 587) as s:
    s.ehlo(); s.starttls(context=ctx); s.ehlo()
    s.login("jdoe@example.com", "userpass")
    s.sendmail("j.doe@example.com", ["taro@example.com"], msg.as_bytes())
PY
```

> `From:` ヘッダを `<uid>@<MAIL_DOMAIN>` に強制したい場合は
> `postfix/main.cf.template` の `sender_canonical_classes` に
> `header_sender` を追加してください。ただし受信メールのヘッダも書き換わる
> ため、DKIM 検証に影響する可能性があります。

---

## 9. ディレクトリ構成

```
.
├── docker-compose.yml
├── .env.example
├── Makefile
├── README.md
├── ldap/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── healthcheck.sh
│   ├── slapd.conf.template
│   ├── schema/mailaccount.schema
│   └── bootstrap/bootstrap.ldif.template
├── postfix/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── main.cf.template
│   ├── master.cf                 # 全サービス chroot=n
│   ├── ldap-virtual-mailbox-maps.cf.template
│   ├── ldap-virtual-alias-maps.cf.template
│   ├── ldap-sender-login-maps.cf.template
│   └── ldap-sender-canonical-maps.cf.template
├── dovecot/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── dovecot.conf
│   ├── dovecot-ldap.conf.ext.template
│   └── sieve/spam.sieve
├── rspamd/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── local.d/*.conf
├── certbot/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── deploy-hook.sh
├── shared/
│   ├── ensure-cert.sh             # 自己署名証明書のブートストラップ
│   └── cert-watch.sh              # 証明書更新時の reload
├── scripts/
│   ├── ldap-add-user.sh
│   ├── ldap-set-forward.sh
│   ├── dkim-record.sh
│   └── lib-env.sh
└── tests/smoke_test.py
```

---

## 10. TLS / certbot

### 10.1 証明書の流れ

1. Postfix / Dovecot は `/etc/ssl/mail/fullchain.pem` と `privkey.pem` を読む。
2. 起動時に証明書が無ければ `shared/ensure-cert.sh` が 30 日間の自己署名証明書を
   生成する (ローカル検証用。クライアントには警告が出る)。
3. `certbot` が `MAIL_HOSTNAME` に対して HTTP-01 (standalone, ポート 80) で
   証明書を取得する。
4. `certbot/deploy-hook.sh` が `/certs` に `fullchain.pem` / `privkey.pem` を
   アトミックに配置する。秘密鍵は `root:5002` (mailcert) の 0640。
5. `shared/cert-watch.sh` が 60 秒ごとにハッシュを比較し、変化があれば
   `postfix reload` / `doveadm reload` を実行する。

### 10.2 初回取得

```bash
# .env
CERTBOT_ENABLED=1
CERTBOT_STAGING=1     # まずステージングで確認
CERTBOT_EMAIL=admin@example.com
```

`make up` 後、`docker compose logs -f certbot` で取得状況を確認します。
DNS とポート 80 が正しければ数秒で取得できます。失敗時は 10 分から最大 6 時間の
バックオフで再試行します。

ステージングで成功したら本番に切り替えます。

```bash
# .env: CERTBOT_STAGING=0
docker compose down
docker volume rm ldap-mail_letsencrypt   # ステージングの lineage を削除
docker compose up -d
make cert-status
```

> ステージング証明書はクライアントから信頼されません。本番運用では必ず
> `CERTBOT_STAGING=0` で取得し直してください。
> 既存の証明書を置き換えるため、`letsencrypt` ボリュームを削除するか
> `certbot delete --cert-name <domain>` を実行します。

### 10.3 ローカルだけ試す

```bash
# .env
CERTBOT_ENABLED=0
CERTBOT_HTTP_PORT=8080   # 80 が使えない場合 (HTTP-01 は本番では 80 必須)
```

自己署名証明書のまま Postfix/Dovecot が起動します。STARTTLS の疎通確認:

```bash
openssl s_client -starttls smtp -connect 127.0.0.1:25 -servername mail.example.com
openssl s_client -starttls imap -connect 127.0.0.1:143 -servername mail.example.com
openssl s_client -connect 127.0.0.1:993 -servername mail.example.com
```

---

## 11. Rspamd / スパム対策

- Postfix の milter (`inet:rspamd:11332`) として動作します。
- 受信メールに `X-Spam-Status`, `X-Spam-Level`, `X-Spam-Flag: YES`,
  `Authentication-Results` を付与します (`skip_authenticated = true` なので
  送信メールには付きません)。
- スコア閾値 (`rspamd/local.d/actions.conf`):
  - `>= 15`: SMTP で reject (`554 5.7.1`)
  - `6 - 14.99`: ヘッダ付与。Dovecot Sieve が `X-Spam-Flag: YES` を見て
    `Junk` に振り分け
  - `< 6`: 通常配送
- DKIM 署名は認証済み送信のみ (`sign_authenticated = true`, `sign_local = false`)。
- `redis` は Bayes の統計保存用です。初期状態では学習データが無いため、
  Bayes はスコアにほとんど影響しません。学習させる場合はコントローラを有効化し、
  `rspamc learn_spam` / `learn_ham` を使ってください
  (`rspamd/local.d/worker-controller.inc` のコメント参照)。
- グレイリスト、レートリミット、レピュテーションはこの構成では無効化しています
  (`rspamd/local.d/*.conf`)。有効化する場合は Redis と各モジュールの設定を
  追加してください。

スパム判定の確認:

```bash
python3 - <<'PY'
import smtplib
msg = (
    "From: spammer@example.net\r\n"
    "To: jdoe@example.com\r\n"
    "Subject: gtube\r\n"
    "\r\n"
    "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X\n"
)
with smtplib.SMTP("127.0.0.1", 25) as s:
    s.ehlo()
    s.mail("spammer@example.net")
    s.rcpt("jdoe@example.com")
    try:
        s.data(msg)     # Rspamd returns 554 for GTUBE
    except smtplib.SMTPDataError as exc:
        print("rejected:", exc.smtp_code, exc.smtp_msg)
PY
```

`jdoe` の INBOX に `X-Spam-Flag` が付いたメールが届いた場合は、Sieve の
`/etc/dovecot/sieve/spam.sieve` が `Junk` に移動します。

---

## 12. 運用

### ログ

```bash
make logs
docker compose logs -f postfix
docker compose logs -f dovecot
docker compose logs -f rspamd
docker compose logs -f certbot
```

### 状態確認

```bash
make ps
docker compose exec postfix postqueue -p
docker compose exec postfix postconf -n
docker compose exec dovecot doveadm auth test jdoe@example.com
docker compose exec dovecot doveadm user jdoe@example.com
make cert-status
```

### バックアップ

メールデータ (`maildata`)、LDAP (`ldap-data`)、Rspamd の DKIM 鍵
(`rspamd-dkim`)、Redis (`redis-data`) をバックアップします。

```bash
mkdir -p backups
docker run --rm -v ldap-mail_maildata:/data:ro -v "$PWD/backups":/backup alpine \
  tar czf /backup/maildata-$(date +%F).tgz -C /data .
docker run --rm -v ldap-mail_ldap-data:/data:ro -v "$PWD/backups":/backup alpine \
  tar czf /backup/ldap-$(date +%F).tgz -C /data .
docker run --rm -v ldap-mail_rspamd-dkim:/data:ro -v "$PWD/backups":/backup alpine \
  tar czf /backup/dkim-$(date +%F).tgz -C /data .
```

Bayes の学習データも残したい場合は Redis の AOF を保存します
(必要なければ省略可)。

```bash
docker compose exec -T redis redis-cli BGSAVE
docker run --rm -v ldap-mail_redis-data:/data:ro -v "$PWD/backups":/backup alpine \
  tar czf /backup/redis-$(date +%F).tgz -C /data .
```

復元はスタックを停止し、同じボリュームに展開します。

```bash
docker compose down
docker run --rm -v ldap-mail_maildata:/data -v "$PWD/backups":/backup alpine \
  sh -c 'tar xzf /backup/maildata-YYYY-MM-DD.tgz -C /data'
docker compose up -d
```

### 更新

```bash
git pull
docker compose build --pull
docker compose up -d
```

### 完全リセット (データ削除)

```bash
make reset     # docker compose down -v
```

---

## 13. テスト

```bash
make up
make test
```

`tests/smoke_test.py` は次のことを確認します。

- Postfix の全 `master.cf` サービスが `chroot=n`
- Dovecot の LDAP userdb が `john.doe@` を `/data/maildir/jdoe` に解決
- `/data/maildir/jdoe` の存在
- 証明書が `MAIL_HOSTNAME` と一致
- 主アドレス / 別名アドレス宛のメールが同じ INBOX に入る
- `asmith@` 宛が `mailForward` で `jdoe@` に転送され、asmith のメールボックスが
  作られない
- 存在しない recipient が 550 で拒否される
- 587 で SMTP AUTH して送信でき、Return-Path が `<uid>@domain` に canonicalize
  され、`From:` が保持され、DKIM-Signature が付く
- 他人の `mail` アドレスを MAIL FROM にすると 553 で拒否される
- GTUBE が SMTP で拒否される
- 別名アドレスで IMAP ログインしても同じ INBOX が見える

手動での確認例:

```bash
# 受信
swaks --to john.doe@example.com --server 127.0.0.1:25 --from outside@example.net

# Submission (要 STARTTLS)
swaks --to taro@example.com --server 127.0.0.1:587 --from j.doe@example.com \
  --auth-user jdoe@example.com --auth-password "$DEMO_USER_PASSWORD" -tls
```

---

## 14. トラブルシューティング

### `550 5.1.1 User unknown in virtual mailbox table`

- 宛先が `mail` 属性に存在するか:
  ```bash
  docker compose exec postfix postmap -q user@example.com \
    ldap:/etc/postfix/ldap-virtual-mailbox-maps.cf
  ```
- `virtual_mailbox_domains` にドメインが入っているか (`postconf -n`)。
- LDAP エントリに `objectClass: mailAccount` があるか。

### `553 5.7.1 Sender address rejected: not owned by user`

- MAIL FROM が認証ユーザーの `mail` に含まれているか:
  ```bash
  docker compose exec postfix postmap -q user@example.com \
    ldap:/etc/postfix/ldap-sender-login-maps.cf
  ```
- Submission は 587 か (25 では SASL AUTH 無効)。
- ログイン名の正規化 (`doveadm auth test` の `user=`) を確認。

### IMAP ログインできない

```bash
docker compose exec dovecot doveadm auth test user@example.com
docker compose exec dovecot doveadm user user@example.com
docker compose logs --tail=50 dovecot
```

- `auth_bind` のため、LDAP の `userPassword` がそのまま使えます。
- `auth_username_format = %Lu` で小文字化されます。

### DKIM が付かない

```bash
docker compose exec rspamd ls -l /var/lib/rspamd/dkim
docker compose logs --tail=100 rspamd | grep -i dkim
make dkim
```

- 認証済み送信か (25 の未認証メールには署名しません)。
- 認証ユーザー名のドメインと `From:` のドメインが一致しているか。
- DNS の `mail._domainkey` が正しいか。

### certbot が失敗する

```bash
docker compose logs --tail=100 certbot
```

- `mail.example.com` の A/AAAA がこのホストを指しているか。
- 外部から TCP/80 に到達できるか。
- 本番のレート制限に達していないか。まず `CERTBOT_STAGING=1` で試す。
- 80 番が他の Web サーバに使われていないか。`CERTBOT_HTTP_PORT` は
  ローカルテスト用で、HTTP-01 は本番では 80 が必要です。

### LMTP で配送されない

```bash
docker compose exec postfix ls -l /var/spool/postfix/private
docker compose logs --tail=50 dovecot
docker compose exec postfix postqueue -p
```

- Dovecot の `dovecot-lmtp` ソケットが共有ボリュームに見えるか。
- 共有ボリュームのパーミッション (Dovecot が root で作成、0666)。

### Rspamd が unhealthy

```bash
docker compose logs --tail=100 rspamd
docker compose exec rspamd rspamadm configtest
```

- このスタックではコントローラ (11334) を無効化しています。Compose の
  ヘルスチェックは PID 1 の生存確認 (`kill -0 1`) だけにしています。milter
  ポートへの単純な TCP 接続は、Rspamd に "abnormally closing milter
  connection" を記録させるためです。
- Rspamd が落ちても Postfix は `milter_default_action = accept` でメールを
  受け付けます (スパム判定なし)。

---

## 15. セキュリティと制約

- **LDAP は Compose ネットワーク内の平文 (`ldap://`)** です。ホスト外に
  公開しないでください。必要なら slapd の TLS と Dovecot/Postfix の
  `ldaps://` 化を追加してください。
- **vmail は単一 UID (5000)** です。全メールボックスが同じ UID で所有される
  ため、OS レベルのユーザー間隔離はありません。厳密な隔離が必要なら
  ユーザーごとの UID に変更してください。
- **Postfix の sender login map は envelope sender のみ**を検証します。
  同じドメイン内で `From:` ヘッダを他人になりすますことは防げません。
  必要なら From ヘッダを検証する milter を追加してください。
- **`mailForward` はローカルコピーを残しません**。コピーが必要な場合は
  Sieve の `redirect` + `keep` などに変更してください。転送ループに注意。
- **単一ドメイン前提**の DKIM 鍵生成です。複数ドメインは
  `virtual_mailbox_domains` と DKIM 鍵の追加が必要です。
- **fail2ban、アンチウイルス、レートリミット、MTA-STS/DANE、POP3、 quota**
  は含みません。
- 25 番を公開するため、Open Relay にならないよう
  `smtpd_relay_restrictions` と Submission の AUTH 必須設定を変更しないでください。
- `.env` は秘密情報です。コミットしないでください (`.gitignore` 済み)。
- Rspamd のコントローラ (11334) は無効化しています。有効化する場合は
  必ずパスワードを設定し、外部に公開しないでください。
- certbot の秘密鍵は `root:5002` (mailcert) の 0640 で、Postfix ユーザーが
  読めるようにしています。ホスト上のファイル権限にも注意してください。

---

## 16. 動作確認済みの範囲

このリポジトリでは、Docker Compose 上で次を実際に確認しています。

- LDAP の複数 `mail` 値が同じ Maildir に配送されること
- `mailForward` による転送と、転送元メールボックスが作られないこと
- 587 の STARTTLS + SMTP AUTH、sender ownership の拒否
- envelope sender の canonicalize と DKIM 署名
- GTUBE の SMTP reject と `X-Spam-Flag` → Junk
- `master.cf` 全サービスの `chroot=n`
- 自己署名証明書での 25/587/143/993 の STARTTLS
- certbot deploy hook による証明書差し替えと Postfix/Dovecot の自動 reload
