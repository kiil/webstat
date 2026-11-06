# Web Push: how a notification reaches a phone with the app closed. The
# same way as Janus: a VAPID-signed POST with an empty body, and the service
# worker fetches /api/notice when it wakes. No payload means no encryption, so
# the only cryptography is an ES256 signature, which openssl does. Nothing here
# needs node or the Mac, so the report goes out when the Mac is asleep.
#
# The key and the subscriptions live in the site's state directory, not in the
# store and not in the checkout, which every deploy replaces. Regenerating the
# key kills every subscription.

const HERE = (path self .)
const MAX_SUBSCRIPTIONS = 20
const SUBJECT = "https://webstat.kiil.cross.stream"

# The push services browsers really use. POST /api/push/subscribe is open like
# the rest of the dashboard, and without this list anyone could make the server
# POST to an address of their choosing.
const ENDPOINT = '^https://(fcm\.googleapis\.com|[a-z0-9.-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com|[a-z0-9.-]+\.push\.services\.mozilla\.com)/'

export def valid-endpoint [endpoint: string]: nothing -> bool {
  ($endpoint | str length) < 1024 and $endpoint =~ $ENDPOINT
}

# The site's durable state directory, else one beside the checkout.
def state-dir []: nothing -> path {
  let dir = ($env | get -o CROSS_STREAM_SITE_STATE | default ($HERE | path join "state"))
  mkdir $dir
  $dir
}

def subs-file []: nothing -> path { (state-dir) | path join "webstat-push.json" }

export def subscriptions []: nothing -> list {
  let f = (subs-file)
  if ($f | path exists) { try { open --raw $f | from json } catch { [] } } else { [] }
}

# Remember an endpoint, keeping the newest. True when it was not known before.
export def subscribe [endpoint: string]: nothing -> bool {
  let known = (subscriptions)
  $known | where {|e| $e != $endpoint } | append $endpoint | last $MAX_SUBSCRIPTIONS | to json | save -f (subs-file)
  $endpoint not-in $known
}

export def forget [endpoints: list]: nothing -> nothing {
  subscriptions | where {|e| $e not-in $endpoints } | to json | save -f (subs-file)
}

def key-file []: nothing -> path {
  let p = ((state-dir) | path join "vapid.pem")
  if not ($p | path exists) {
    ^openssl ecparam -genkey -name prime256v1 -noout -out $p
    ^chmod 600 $p
  }
  $p
}

# base64url without padding, what JWS and applicationServerKey both want.
def b64url []: any -> string {
  $in | encode base64 | str replace -a "+" "-" | str replace -a "/" "_" | str replace -a "=" ""
}

# The applicationServerKey: the public key as an uncompressed EC point, the
# last 65 bytes of the SubjectPublicKeyInfo.
export def public-key []: nothing -> string {
  let der = (mktemp -t "webstat-vapid.XXXXXX")
  ^openssl ec -in (key-file) -pubout -outform DER -out $der err>| ignore
  let b = (open --raw $der | into binary)
  rm -f $der
  $b | bytes at (($b | bytes length) - 65).. | b64url
}

def pad32 [v: list<string>]: nothing -> list<string> {
  let t = if ($v | length) > 32 { $v | last 32 } else { $v }
  let n = ($t | length)
  if $n == 32 { $t } else { (0..<(32 - $n) | each { "00" }) ++ $t }
}

# ECDSA DER signature to JWS raw R||S. It stays in hex pairs the whole way, as
# a round trip through ints is where a leading zero byte goes missing.
def der-to-raw [der: binary]: nothing -> binary {
  let b = ($der | encode hex | split chars | chunks 2 | each {|c| $c | str join })
  let lr = ($b | get 3 | into int --radix 16)
  let r = ($b | slice 4..<(4 + $lr))
  let so = (4 + $lr)
  let ls = ($b | get ($so + 1) | into int --radix 16)
  let s = ($b | slice ($so + 2)..<($so + 2 + $ls))
  ((pad32 $r) ++ (pad32 $s)) | str join | decode hex
}

def sign [input: string]: nothing -> binary {
  let msg = (mktemp -t "webstat-jwt.XXXXXX")
  let sig = (mktemp -t "webstat-sig.XXXXXX")
  $input | save -f --raw $msg
  ^openssl dgst -sha256 -sign (key-file) -out $sig $msg
  let der = (open --raw $sig | into binary)
  rm -f $msg $sig
  der-to-raw $der
}

# A VAPID token for one push service; `aud` is the endpoint's origin.
export def jwt [endpoint: string]: nothing -> string {
  let u = ($endpoint | url parse)
  let header = ({typ: "JWT", alg: "ES256"} | to json -r | b64url)
  let exp = ((date now | format date "%s" | into int) + 43200)
  let claims = ({aud: $"($u.scheme)://($u.host)", exp: $exp, sub: $SUBJECT} | to json -r | b64url)
  let input = $"($header).($claims)"
  $"($input).(sign $input | b64url)"
}

# Wake one subscription. `gone` means the browser threw it away.
export def send [endpoint: string, --ttl: int = 21600]: nothing -> record {
  let status = (try {
    http post --full --allow-errors --content-type "application/octet-stream" --headers {
      Authorization: $"vapid t=(jwt $endpoint),k=(public-key)"
      TTL: ($ttl | into string)
      Urgency: "normal"
    } $endpoint 0x[] | get -o status | default 0
  } catch {|e|
    print -e $"webstat push: ($e.msg)"
    0
  })
  {endpoint: $endpoint, ok: ($status >= 200 and $status < 300), gone: ($status in [404 410])}
}
