// S3 requests: AWS Signature Version 4 and the few replies cloud saves read (runtime/ui/cloud.mm). Any S3-compatible
// storage takes them: Backblaze B2, Cloudflare R2, MinIO, AWS. Path-style URLs (https://<host>/<bucket>/<key>).
#pragma once
#include <ctime>
#include <string>
#include <utility>
#include <vector>
#include <algorithm>

#include "../cache_sha256.h"

namespace s3 {

using Headers = std::vector<std::pair<std::string, std::string>>;

inline std::string sha256_hex(const void *p, size_t n) {
    CacheSha256 h;
    h.add(p, n);
    return h.finish();
}
inline std::string sha256_hex(const std::string &s) { return sha256_hex(s.data(), s.size()); }
inline std::string unhex(const std::string &h) {
    std::string out;
    auto v = [](char c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; };
    for (size_t i = 0; i + 1 < h.size(); i += 2) out += (char)(v(h[i]) << 4 | v(h[i + 1]));
    return out;
}
inline std::string hmac(const std::string &key, const std::string &msg) {
    std::string k = key.size() > 64 ? unhex(sha256_hex(key)) : key;
    k.resize(64, '\0');
    std::string ipad(64, '\0'), opad(64, '\0');
    for (int i = 0; i < 64; i++) ipad[i] = k[i] ^ 0x36, opad[i] = k[i] ^ 0x5c;
    return unhex(sha256_hex(opad + unhex(sha256_hex(ipad + msg))));
}
// RFC 3986 percent-encoding, as SigV4 wants it: all but A-Z a-z 0-9 - _ . ~ (and '/' in a path)
inline std::string encode(const std::string &s, bool path = false) {
    static const char hex[] = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : s) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~' || (path && c == '/')) out += (char)c;
        else out += '%', out += hex[c >> 4], out += hex[c & 15];
    }
    return out;
}
inline std::string lower(std::string s) {
    for (char &c : s) c = (char)tolower((unsigned char)c);
    return s;
}
inline std::string trim(const std::string &s) {
    size_t a = s.find_first_not_of(" \t"), b = s.find_last_not_of(" \t");
    return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

// Signs a request: adds x-amz-date (and, for S3, x-amz-content-sha256) and Authorization to headers, which must
// already hold every other header to send (host first among them is not required). path: the URL's path, not yet
// encoded ("/bucket/key"); query: its parameters, not yet encoded. Returns the encoded query string for the URL.
inline std::string sign(const std::string &method, const std::string &path, std::vector<std::pair<std::string, std::string>> query,
                        Headers &headers, const std::string &payload_hash, const std::string &region, const std::string &key_id,
                        const std::string &secret, time_t now, const std::string &service = "s3") {
    char date[32], day[16];
    struct tm tm;
    gmtime_r(&now, &tm);
    strftime(date, sizeof date, "%Y%m%dT%H%M%SZ", &tm);
    strftime(day, sizeof day, "%Y%m%d", &tm);
    headers.push_back({"x-amz-date", date});
    if (service == "s3") headers.push_back({"x-amz-content-sha256", payload_hash});

    for (auto &q : query) q = {encode(q.first), encode(q.second)};
    std::sort(query.begin(), query.end());
    std::string qs;
    for (auto &q : query) qs += (qs.empty() ? "" : "&") + q.first + "=" + q.second;
    Headers canon;
    for (auto &h : headers) canon.push_back({lower(h.first), trim(h.second)});
    std::sort(canon.begin(), canon.end());
    std::string ch, signed_headers;
    for (auto &h : canon) {
        ch += h.first + ":" + h.second + "\n";
        signed_headers += (signed_headers.empty() ? "" : ";") + h.first;
    }
    std::string request = method + "\n" + encode(path, true) + "\n" + qs + "\n" + ch + "\n" + signed_headers + "\n" + payload_hash;
    std::string scope = std::string(day) + "/" + region + "/" + service + "/aws4_request";
    std::string to_sign = "AWS4-HMAC-SHA256\n" + std::string(date) + "\n" + scope + "\n" + sha256_hex(request);
    std::string k = hmac(hmac(hmac(hmac("AWS4" + secret, day), region), service), "aws4_request");
    static const char hex[] = "0123456789abcdef";
    std::string sig;
    for (unsigned char c : hmac(k, to_sign)) sig += hex[c >> 4], sig += hex[c & 15];
    headers.push_back({"Authorization", "AWS4-HMAC-SHA256 Credential=" + key_id + "/" + scope +
                                            ", SignedHeaders=" + signed_headers + ", Signature=" + sig});
    return qs;
}

// The text of each <tag>...</tag> in xml, in order (S3's replies are flat enough for this), entities decoded
inline std::vector<std::string> xml_all(const std::string &xml, const std::string &tag) {
    std::vector<std::string> out;
    std::string open = "<" + tag + ">", close = "</" + tag + ">";
    for (size_t at = 0; (at = xml.find(open, at)) != std::string::npos;) {
        size_t b = at + open.size(), e = xml.find(close, b);
        if (e == std::string::npos) break;
        std::string v = xml.substr(b, e - b), d;
        for (size_t i = 0; i < v.size(); i++) {
            static const char *const ent[][2] = {{"&amp;", "&"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}};
            bool hit = false;
            for (auto &x : ent)
                if (!v.compare(i, strlen(x[0]), x[0])) { d += x[1], i += strlen(x[0]) - 1, hit = true; break; }
            if (!hit) d += v[i];
        }
        out.push_back(d);
        at = e + close.size();
    }
    return out;
}
inline std::string xml_one(const std::string &xml, const std::string &tag) {
    auto v = xml_all(xml, tag);
    return v.empty() ? "" : v[0];
}

}  // namespace s3
