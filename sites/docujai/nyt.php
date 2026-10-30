<?php

/**
 * @file
 * First-party collector for webstat on docujai.com, deployed as
 * public_html/nyt.php. Made after klimaleksikon.dk's.
 *
 * The beacon from docujai_webstat/js/webstat.js posts here, on the site's own
 * domain, so ad blockers that stop requests to other hosts leave it alone.
 * The request is answered at once (204) and then passed on to
 * https://webstat.kiil.cross.stream/hit together with the reader's IP (the
 * remote address; docujai.com is served directly) and the key in
 * ~/.webstat-key (/var/www/docujai.com). webstat hashes the IP with a daily
 * salt and stores neither. Nothing is stored here.
 *
 * Calls to webstat give up after one second, so an outage there never ties
 * up the PHP processes Drupal needs.
 *
 * Not a Drupal script: a plain PHP file that LiteSpeed serves directly. POST
 * requests are never cached by LiteSpeed or Cloudflare.
 */

const WEBSTAT = 'https://webstat.kiil.cross.stream';
const ORIGINS = ['https://docujai.com', 'https://www.docujai.com'];

header('Cache-Control: no-store');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
  http_response_code(405);
  exit;
}

// Same-origin POSTs carry Origin in current browsers; fall back to Referer.
$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
if ($origin === '' && !empty($_SERVER['HTTP_REFERER'])) {
  $parts = parse_url($_SERVER['HTTP_REFERER']);
  $origin = ($parts['scheme'] ?? '') . '://' . ($parts['host'] ?? '');
}
if (!in_array($origin, ORIGINS, TRUE)) {
  http_response_code(403);
  exit;
}
$body = (string) file_get_contents('php://input', FALSE, NULL, 0, 4096);
$ua = (string) ($_SERVER['HTTP_USER_AGENT'] ?? '');
$ip = (string) ($_SERVER['REMOTE_ADDR'] ?? '');
$purpose = (string) ($_SERVER['HTTP_SEC_PURPOSE'] ?? '');

// Answer the reader first; forwarding happens after the response is sent.
http_response_code(204);
if (function_exists('litespeed_finish_request')) {
  litespeed_finish_request();
}
elseif (function_exists('fastcgi_finish_request')) {
  fastcgi_finish_request();
}

if ($body === '' || $ua === '') {
  exit;
}
$key = trim((string) @file_get_contents(dirname(__DIR__) . '/.webstat-key'));
$headers = [
  'Content-Type: text/plain',
  'Origin: ' . $origin,
  'User-Agent: ' . $ua,
  'X-Webstat-Key: ' . $key,
  'X-Webstat-Ip: ' . $ip,
];
if ($purpose !== '') {
  $headers[] = 'Sec-Purpose: ' . $purpose;
}
$ch = curl_init(WEBSTAT . '/hit');
curl_setopt_array($ch, [
  CURLOPT_POST => TRUE,
  CURLOPT_POSTFIELDS => $body,
  CURLOPT_HTTPHEADER => $headers,
  CURLOPT_RETURNTRANSFER => TRUE,
  CURLOPT_TIMEOUT => 1,
]);
curl_exec($ch);
