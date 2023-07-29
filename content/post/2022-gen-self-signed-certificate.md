---
title: "Generate Self-Signed Certificate"
date: 2022-07-06T14:16:05+08:00
lastmod: 2023-05-01T14:16:05+08:00
draft: false
keywords: ["ssl", "tls", "go"]
description: "Generate Self-Signed Certificate"
tags: ["ssl", "tls", "go", "en"]
author: "Zeng Xu"
summary: "Notes on generating a self-signed certificate using OpenSSL, CFSSL, and Golang"

comment: true
toc: true
autoCollapseToc: false
postMetaInFooter: true
hiddenFromHomePage: false
contentCopyright:  '本作品采用 <a rel="license noopener" href="https://creativecommons.org/licenses/by-nc-nd/4.0/" target="_blank">知识共享署名-非商业性使用-禁止演绎 4.0 国际许可协议</a> 进行许可，转载时请注明原文链接。'    
reward: false
mathjax: false
mathjaxEnableSingleDollar: false
mathjaxEnableAutoNumber: false

# You unlisted posts you might want not want the header or footer to show
hideHeaderAndFooter: false
---

## OpenSSL

[OpenSSL] needs no introduction.

Generating a Certificate Authority (CA) Using OpenSSL

- Replacing `-newkey ec -pkeyopt ec_paramgen_curve:prime256v1` with `-newkey rsa:4096` to use RSA key.
- Full Subject options are `/C=County/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=CommonNameOrHostname`.

```shell
openssl req -x509 -nodes -days 365 \
-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
-keyout ca.key -out ca.crt \
-subj  "/O=Zeng/CN=CA" \
-addext "keyUsage=critical, keyCertSign, cRLSign"
```

You can utilize the generated CA to sign certificates.


```shell
openssl req -new -nodes \
-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
-keyout kube-apiserver.key -out kube-apiserver.csr \
-subj "/O=system:masters/CN=kube-apiserver" \
-addext "basicConstraints=critical,CA:FALSE" \
-addext "keyUsage=digitalSignature,keyEncipherment" \
-addext "extendedKeyUsage=serverAuth" \
-addext "subjectAltName=DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:localhost,IP:127.0.0.1"

openssl x509 -req -sha256 -days 3650 -copy_extensions=copy \
-in kube-apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
-out kube-apiserver.crt
```
For versions of [OpenSSL] prior to v3.0.0, you should generate the CSR and certificate like below. Please refer to the discussion [Missing X509 extensions with an openssl-generated certificate](https://security.stackexchange.com/questions/150078/missing-x509-extensions-with-an-openssl-generated-certificate).

```shell
openssl req -new -nodes \
-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
-subj "/O=system:masters/CN=kube-apiserver" \
-keyout kube-apiserver.key -out kube-apiserver.csr

openssl x509 -req -sha256 -days 3650 \
-in kube-apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
-out kube-apiserver.crt -extensions v3_req \
-extfile <(printf "[v3_req]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,IP:127.0.0.1")
```

Full options can be found at  [OpenSSL x509v3_config].

## CFSSL

> CFSSL is CloudFlare's PKI/TLS swiss army knife. 
> It is both a command line tool and an HTTP API server for signing, verifying, and bundling TLS certificates.

CFSSL is more easier than OpenSSL. 
Option groups can be pre-defined in CA config, and reused to generate TLS certificates numbers of components in large system.

```shell
{
cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "ecdsa",
    "size": 521
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

}
```

The `ca-config.json` file, particularly the profiles section, can be reused as template to issue series of certificates.

```shell
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF
```
Next we use root CA to issue a certificate, with profile `kubernetes` and other default configs in `ca-config.json` defined previously.

```shell
{

cat > admin-client.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin

}
```

## Programmatic Way

Using Golang as an exmaple. (One of Rust example is [est31/rcgen]).

[Golang std crypto/tls/generate_cert.go] provides a simple way to generate self-signed certificate.

- `host` configures the `Subject Alternative Name` (SAN). `SAN` is an extension to the X.509 specification that allows users to specify additional identities for a single SSL certificate. Defined options include an email address, a DNS name, an IP address, and a uniform resource identifier (URI).
- `ca` configures whether this cert should be its own Certificate Authority
- `ecdsa-curve` is ECDSA curve to use to generate a key. Valid values are P224, P256 (recommended), P384, P521
- `rsa-bits` is Size of RSA key to generate. Ignored if --ecdsa-curve is set

It can be compile to binary by `go build generate_cert.go` so as to use as command tool.

The output certificate have fix `Issuer: O=Acme Co` and `Subject: O=Acme Co` (useful in some scope, like mTLS). Changing the code and making it as arguments overcome this shortcoming.

It is very suitable for the following cases: 
1. testing
2. webhook plugin: large system such as Kubernetes requires that the webhook server must use the HTTPS protocol

It is not suitable for complex scenarios, such as generating certificate chains.

```shell
$ wget https://raw.githubusercontent.com/golang/go/master/src/crypto/tls/generate_cert.go

# replace --ecdsa-curve P256 with --rsa-bits 2048 to generate RSA key
$ go run generate_cert.go --host example.com,127.0.0.1,::1  --ecdsa-curve P256 --ca --start-date "Jan 1 00:00:00 1970" --duration=1000000h
2022/07/06 17:57:16 wrote cert.pem
2022/07/06 17:57:16 wrote key.pem

$ openssl x509 -in cert.pem -text -noout
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            b0:01:ee:99:c9:29:f7:50:25:29:12:e4:c8:7e:17:c4
    Signature Algorithm: ecdsa-with-SHA256
        Issuer: O=Acme Co
        Validity
            Not Before: Jan  1 00:00:00 1970 GMT
            Not After : Jan 29 16:00:00 2084 GMT
        Subject: O=Acme Co
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                pub: 
                    04:70:da:c2:1e:02:ac:d7:23:0c:53:cc:f2:70:df:
                    30:3f:16:e5:fd:ce:18:b6:48:9f:02:e4:25:29:54:
                    5b:07:8c:1e:92:cd:25:94:f7:81:e3:fe:76:8c:b0:
                    26:84:49:8c:92:3e:85:1e:0e:bf:21:bd:4a:95:a7:
                    71:ed:b4:db:fb
                ASN1 OID: prime256v1
                NIST CURVE: P-256
        X509v3 extensions:
            X509v3 Key Usage: critical
                Digital Signature, Certificate Sign
            X509v3 Extended Key Usage: 
                TLS Web Server Authentication
            X509v3 Basic Constraints: critical
                CA:TRUE
            X509v3 Subject Key Identifier: 
                7F:7C:6F:06:36:E3:E9:E7:8D:12:69:BB:E5:F5:4B:4C:C4:8D:B8:D8
            X509v3 Subject Alternative Name: 
                DNS:example.com, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1
    Signature Algorithm: ecdsa-with-SHA256
         30:45:02:20:15:e2:32:3c:47:ff:a5:fc:00:83:cf:e3:4c:60:
         7d:2e:51:26:0a:bd:b3:44:ba:08:f6:3b:e4:79:62:63:c4:d6:
         02:21:00:b7:62:55:e4:b0:19:f0:7f:ad:60:b2:bf:dc:73:09:
         2f:02:9a:5d:dc:58:8b:99:79:69:de:be:34:3e:74:3e:20
```

## Further Reading
1. [X.509 specification]
2. [OpenSSL x509v3_config]
3. [Introducing CFSSL - CloudFlare's PKI toolkit]
4. [kubernetes-the-hard-way/Provisioning a CA and Generating TLS Certificates]
5. [cfssl 核心模块分析]
6. [Golang std crypto/tls/generate_cert.go]
7. [est31/rcgen]

[X.509 specification]: https://www.ietf.org/rfc/rfc2459.txt

[OpenSSL]: https://github.com/openssl/openssl
[OpenSSL x509v3_config]: https://www.openssl.org/docs/manmaster/man5/x509v3_config.html

[CFSSL]: https://github.com/cloudflare/cfssl
[Introducing CFSSL - CloudFlare's PKI toolkit]: https://blog.cloudflare.com/introducing-cfssl/
[cfssl 核心模块分析]: https://mayo.rocks/2021/11/cfssl-%E6%A0%B8%E5%BF%83%E6%A8%A1%E5%9D%97%E5%88%86%E6%9E%90/
[kubernetes-the-hard-way/Provisioning a CA and Generating TLS Certificates]: https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/04-certificate-authority.md

[Golang std crypto/tls/generate_cert.go]: https://raw.githubusercontent.com/golang/go/master/src/crypto/tls/generate_cert.go
[est31/rcgen]: https://github.com/est31/rcgen