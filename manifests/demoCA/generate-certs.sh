#!/bin/bash

openssl genrsa -out manifests/demoCA/tls.key 4096
openssl req -new -x509 -days 1825 -key manifests/demoCA/tls.key -out manifests/demoCA/tls.crt -subj "/C=AU/ST=NSW/L=Sydney/O=Global Security/OU=IT Department/CN=example.com"
# If on mac find openssl under `/usr/local/Cellar/openssl...` and use it instead of the default openssl. 