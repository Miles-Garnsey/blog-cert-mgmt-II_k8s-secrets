---
layout: post
title: Certificates management and Cassandra Pt II - cert-manager and Kubernetes
author: Miles Garnsey
category: blog
tags: cassandra, kubernetes, cert-manager, certificates, apache, ssl, security, keys, encryption
---

## The joys of certificate management

Certificate management has long been a bugbear of enterprise environments, and expired certs have been the cause of countless [outages](https://techcrunch.com/2021/09/21/lets-encrypt-root-expiry/). When managing large numbers of services at scale, it helps to have an automated approach to managing certs in order to handle renewal and avoid embarrassing and avoidable downtime.

This is part II of our exploration of certificates and encrypting Cassandra. In this blog post, we will dive into certificate management in Kubernetes. This post builds on a few of the concepts in [Part I](https://thelastpickle.com/blog/2021/06/15/cassandra-certificate-management-part_1-how-to-rotate-keys.html) of this series, where Anthony explained the components of SSL encryption.

Recent years have seen the rise of some fantastic, free, automation-first services like [letsencrypt](https://letsencrypt.org), and no one should be caught flat footed by certificate renewals in 2021. In this blog post, we will look at one Kubernetes native tool that aims to make this process much more ergonomic on Kubernetes; [`cert-manager`](https://cert-manager.io).

### Recap

Anthony has already discussed several points about certificates. To recap:

1. In asymmetric encryption and digital signing processes we always have public/private key pairs. We are referring to these as the Keystore Private Signing Key (KS PSK) and Keystore Public Certificate (KS PC). 
2. Public keys can always be openly published and allow senders to communicate to the holder of the matching private key.
3. A certificate is just a public key - and some additional fields - which has been signed by a certificate authority (CA). A CA is a party trusted by all parties to an encrypted conversation.
4. When a CA signs a certificate, this is a way for that mutually trusted party to attest that the party holding that certificate is who they say they are.
5. CA's themselves use public certificates (Certificate Authority Public Certificate; CA PC) and private signing keys (the Certificate Authority Private Signing Key; CA PSK) to sign certificates in a verifiable way.

# The many certificates that Cassandra might be using

In a moderately complex Cassandra configuration, we might have:

1. A root CA (cert A) for internode encryption.
2. A certificate per node signed by cert A.
3. A root CA (cert B) for the client-server encryption.
4. A certificate per node signed by cert B.
5. A certificate per client signed by cert B.

Even in a three node cluster, we can envisage a case where we must create two root CAs and 6 certificates, plus a certificate for each client application; for a total of 8+ certificates!

To compound the problem, this isn't a one-off setup. Instead, we need to be able to rotate these certificates at regular intervals as they expire.

## Ergonomic certificate management on Kubernetes with cert-manager

Thankfully, these processes are well supported on Kubernetes by a tool called `cert-manager`.

`cert-manager` is an all-in-one tool that should save you from ever having to reach for `openssl` or `keytool` again. As a Kubernetes operator, it manages a variety of custom resources (CRs) such as (Cluster)Issuers, CertificateRequests and Certificates. Critically it integrates with Automated Certificate Management Environment (ACME) `Issuer`s, such as LetsEncrypt (which we will not be discussing today).

The workfow reduces to:

1. Create an `Issuer` (via ACME, or a custom CA).
2. Create a Certificate CR.
3. Pick up your certificates and signing keys from the secrets `cert-manager` creates, and mount them as volumes in your pods' containers.

Everything is managed declaratively, and you can reissue certificates at will simply by deleting and re-creating the certificates and secrets. 

Or you can use the [`kubectl`](https://cert-manager.io/docs/usage/kubectl-plugin/) plugin which allows you to write a simple `kubectl cert-manager renew`. We won't discuss this in depth here, see the `cert-manager` [documentation](https://cert-manager.io/docs/usage/kubectl-plugin/) for more information

## Java batteries included (mostly)

At this point, Cassandra users are probably about to interject with a loud "Yes, but I need keystores and truststores, so this solution only gets me halfway". As luck would have it, from [version .15](https://cert-manager.io/docs/release-notes/release-notes-0.15/#general-availability-of-jks-and-pkcs-12-keystores), `cert-manager` also allows you to create JKS truststores and keystores directly from the Certificate CR. 

## The fine print

There are two caveats to be aware of here:

1. Most Cassandra deployment options currently available (including statefulSets, `cass-operator` or k8ssandra) do not currently support using a cert-per-node configuration in a convenient fashion. This is because the `PodTemplate.spec` portions of these resources are identical for each pod in the StatefulSet. This precludes the possibility of adding per-node certs via environment or volume mounts.
2. There are currently some open questions about how to rotate certificates without downtime when using internode encryption. 
  a. Our current recommendation is to use a CA PC per Cassandra datacenter (DC) and add some basic scripts to merge both CA PCs into a single truststore to be propagated across all nodes. By renewing the CA PC independently you can ensure one DC is always online, but you still do suffer a network partition. Hinted handoff should theoretically rescue the situation but it is a less than robust solution, particularly on larger clusters. This solution is not recommended when using lightweight transactions or non `LOCAL` consistency levels.
  b. One mitigation to consider is using non-expiring CA PCs, in which case no CA PC rotation is ever performed without a manual trigger. KS PCs and KS PSKs may still be rotated. When CA PC rotation is essential this approach allows for careful planning ahead of time, but it is not always possible when using a 3rd party CA.
  c. [Istio](https://istio.io/) or other service mesh approaches can fully automate mTLS in clusters, but Istio is a fairly large committment and can create its own complexities.
  d. Manual management of certificates may be possible using a secure vault (e.g. [HashiCorp vault](https://www.vaultproject.io/)), [sealed secrets](https://github.com/bitnami-labs/sealed-secrets), or similar approaches. In this case, cert manager may not be involved.

These caveats are not trivial. To address (2) more elegantly you could also implement Anthony's solution from [part one](https://thelastpickle.com/blog/2021/06/15/cassandra-certificate-management-part_1-how-to-rotate-keys.html) of this blog series; but you'll need to script this up yourself to suit your k8s environment.

We are also in [discussions](https://github.com/jetstack/cert-manager/issues/4344) with the folks over at cert-manager about how their ecosystem can better support Cassandra. We hope to report progress on this front over the coming months.

These caveats present challenges, but there are also specific cases where they matter less.

## cert-manager and Reaper - a match made in heaven

One case where we really don't care if a client is unavailable for a short period is when [Reaper](http://cassandra-reaper.io) is the client. 

Cassandra is an eventually consistent system and suffers from entropy. Data on nodes can become out of sync with other nodes due to transient network failures, node restarts and the general wear and tear incurred by a server operating 24/7 for several years.

Cassandra contemplates that this may occur. It provides a variety of consistency level settings allowing you to control how many nodes must agree for a piece of data to be considered the truth. But even though properly set consistency levels ensure that the data returned will be accurate, the process of reconciling data across the network degrades read performance - it is best to have consistent data on hand when you go to read it.

As a result, we recommend the use of Reaper, which runs as a Cassandra client and automatically repairs the cluster in a slow trickle, ensuring that a high volume of repairs are not scheduled all at once (which would overwhelm the cluster and degrade the performance of real clients) while also making sure that all data is eventually repaired for when it is needed.

# The set up

The manifests for this blog post can be found [here](https://github.com/thelastpickle/blog-cert-mgmt-II_k8s-secrets).

## Environment

We assume that you're running Kubernetes 1.21, and we'll be running with a Cassandra 3.11.10 install. The demo environment we'll be setting up is a 3 node environment, and we have tested this configuration against 3 nodes. 

We will be installing the `cass-operator` and Cassandra cluster into the `cass-operator` namespace, while the `cert-manager` operator will sit within the `cert-manager` namespace. 

### Setting up kind

For testing, we often use `kind` to provide a local k8s cluster. You can use `minikube` or whatever solution you prefer (including a real cluster running on GKE, EKS, or AKS), but we'll include some `kind` instructions and scripts here to ease the way.

If you want a quick fix to get you started, try running the `setup-kind-multicluster.sh` script from the k8ssandra-operator [repository](https://github.com/k8ssandra/k8ssandra-operator), with `setup-kind-multicluster.sh --kind-worker-nodes 3`. I have included this script in the root of the code examples repo that accompanies this blog.

## A demo CA certificate

We aren't going to use LetsEncrypt for this demo, firstly because ACME certificate issuance has some complexities (including needing a DNS or a publicly hosted HTTP server) and secondly because I want to reinforce that `cert-manager` is useful to organisations who are bringing their own certs and don't need one issued. This is especially useful for on-prem deployments.

First off, create a new private key and certificate pair for your root CA. Note that the file names tls.crt and tls.key will become important in a moment.

```
openssl genrsa -out manifests/demoCA/tls.key 4096
openssl req -new -x509 -key manifests/demoCA/tls.key -out manifests/demoCA/tls.crt -subj "/C=AU/ST=NSW/L=Sydney/O=Global Security/OU=IT Department/CN=example.com"
```

(Or you can just run the `generate-certs.sh` script in the manifests/demoCA directory - ensure you run it from the root of the project so that the secrets appear in `.manifests/demoCA/`.)

When running this process on MacOS be aware of [this](https://github.com/jetstack/cert-manager/issues/279) issue which affects the creation of self signed certificates. The repo referenced in this blog post contains example certificates which you can use for demo purposes - but do not use these outside your local machine.

Now we're going to use `kustomize` (which comes with `kubectl`) to add these files to Kubernetes as secrets. `kustomize` is not a templating language like Helm. But it fulfills a similar role by allowing you to build a set of base manifests that are then bundled, and which can be customised for your particular deployment scenario by patching.

Run `kubectl apply -k manifests/demoCA`. This will build the secrets resources using the `kustomize` secretGenerator and add them to Kubernetes. Breaking this process down piece by piece:

```
# ./manifests/demoCA
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cass-operator
generatorOptions:
 disableNameSuffixHash: true
secretGenerator:
- name: demo-ca
  type: tls
  files:
  - tls.crt
  - tls.key
```

* We use `disableNameSuffixHash`, because otherwise `kustomize` will add hashes to each of our secret names. This makes it harder to build these deployments one component at a time.
* The `tls` type secret conventionally takes two keys with these names, as per the next point. `cert-manager` expects a secret in this format in order to create the Issuer which we will explain in the next step.
* We are adding the files tls.crt and tls.key. The file names will become the keys of a secret called demo-ca.

### cert-manager

`cert-manager` can be installed by running `kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml`. It will install into the `cert-manager` namespace because a Kubernetes cluster should only ever have a single `cert-manager` operator installed. 

`cert-manager` will install a deployment, as well as various custom resource definitions (CRDs) and webhooks to deal with the lifecycle of the Custom Resources (CRs).

### A cert-manager Issuer

Issuers come in various forms. Today we'll be using a [CA `Issuer`](https://cert-manager.io/docs/configuration/ca/) because our components need to trust each other, but don't need to be trusted by a web browser.

Other options include ACME based `Issuer`s compatible with LetsEncrypt, but these would require that we have control of a public facing DNS or HTTP server, and that isn't always the case for Cassandra, especially on-prem.

Dive into the `truststore-keystore` directory and you'll find the `Issuer`, it is very simple so we won't reproduce it here. The only thing to note is that it takes a secret which has keys of `tls.crt` and `tls.key` - the secret you pass in must have these keys. These are the CA PC and CA PSK we mentioned earlier.

We'll apply this manifest to the cluster in the next step.

### Some cert-manager certs

Let's start with the `Cassandra-Certificate.yaml` resource: 

```
spec:
  # Secret names are always required.
  secretName: cassandra-jks-keystore
  duration: 2160h # 90d
  renewBefore: 360h # 15d
  subject:
    organizations:
    - datastax
  dnsNames:
  - dc1.cass-operator.svc.cluster.local
  isCA: false
  usages:
    - server auth
    - client auth
  issuerRef:
    name: ca-issuer
    # We can reference ClusterIssuers by changing the kind here.
    # The default value is `Issuer` (i.e. a locally namespaced Issuer)
    kind: Issuer
    # This is optional since cert-manager will default to this value however
    # if you are using an external issuer, change this to that `Issuer` group.
    group: cert-manager.io
  keystores:
    jks:
      create: true
      passwordSecretRef: # Password used to encrypt the keystore
        key: keystore-pass
        name: jks-password
  privateKey:
    algorithm: RSA
    encoding: PKCS1
    size: 2048
```

The first part of the spec here tells us a few things:

* The keystore, truststore and certificates will be fields within a secret called `cassandra-jks-keystore`. This secret will end up holding our KS PSK and KS PC.
* It will be valid for 90 days.
* 15 days before expiry, it will be renewed automatically by cert manager, which will contact the `Issuer` to do so.
* It has a subject organisation. You can add any of the X509 subject fields here, but it needs to have one of them.
* It has a DNS name - you could also provide a URI or IP address. In this case we have used the service address of the Cassandra datacenter which we are about to create via the operator. This has a format of `<DC_NAME>.<NAMESPACE>.svc.cluster.local`.
* It is not a CA (`isCA`), and can be used for server auth or client auth (`usages`). You can tune these settings according to your needs. If you make your cert a CA you can even reference it in a new `Issuer`, and define cute tree like structures (if you're into that).

Outside the certificates themselves, there are additional settings controlling how they are issued and what format this happens in.

* `IssuerRef` is used to define the `Issuer` we want to issue the certificate. The `Issuer` will sign the certificate with its CA PSK.
* We are specifying that we would like a keystore created with the `keystore` key, and that we'd like it in `jks` format with the corresponding key.
* `passwordSecretKeyRef` references a secret and a key within it. It will be used to provide the password for the keystore (the truststore is unencrypted as it contains only public certs and no signing keys).

The `Reaper-Certificate.yaml` is similar in structure, but has a different DNS name. We aren't configuring Cassandra to verify that the DNS name on the certificate matches the DNS name of the parties in this particular case.

Apply all of the certs and the `Issuer` using `kubectl apply -k manifests/truststore-keystore`.

### Cass-operator

Examining the `cass-operator` directory, we'll see that there is a  `kustomization.yaml` which references the remote cass-operator repository and a local `cassandraDatacenter.yaml`. This applies the manifests required to run up a `cass-operator` installation namespaced to the `cass-operator` namespace. 

Note that this installation of the operator will only watch its own namespace for CassandraDatacenter CRs. So if you create a DC in a different namespace, nothing will happen.

We will apply these manifests in the next step.

### CassandraDatacenter

Finally, the `CassandraDatacenter` resource in the `./cass-operator/` directory will describe the kind of DC we want:

```
apiVersion: cassandra.datastax.com/v1beta1
kind: CassandraDatacenter
metadata:
  name: dc1
spec:
  clusterName: cluster1
  serverType: cassandra
  serverVersion: 3.11.10
  managementApiAuth:
    insecure: {}
  size: 1
  podTemplateSpec:
    spec:
      containers:
        - name: "cassandra"
          volumeMounts:
          - name: certs
            mountPath: "/crypto"
      volumes:
      - name: certs
        secret:
          secretName: cassandra-jks-keystore
  storageConfig:
    cassandraDataVolumeClaimSpec:
      storageClassName: standard
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
          storage: 5Gi
  config:
    cassandra-yaml:
      authenticator: org.apache.cassandra.auth.AllowAllAuthenticator
      authorizer: org.apache.cassandra.auth.AllowAllAuthorizer
      role_manager: org.apache.cassandra.auth.CassandraRoleManager
      client_encryption_options:
        enabled: true
        # If enabled and optional is set to true encrypted and unencrypted connections are handled.
        optional: false
        keystore: /crypto/keystore.jks
        keystore_password: dc1
        require_client_auth: true
        # Set trustore and truststore_password if require_client_auth is true
        truststore: /crypto/truststore.jks
        truststore_password: dc1
        protocol: TLS
        cipher_suites: [TLS_RSA_WITH_AES_128_CBC_SHA]
      server_encryption_options:
        internode_encryption: all
        keystore: /crypto/keystore.jks
        keystore_password: dc1
        truststore: /crypto/truststore.jks
        truststore_password: dc1
    jvm-options:
      initial_heap_size: 800M
      max_heap_size: 800M
```

* We provide a name for the DC - dc1.
* We provide a name for the cluster - the DC would join other DCs if they already exist in the k8s cluster and we configured the `additionalSeeds` property.
* We use the `podTemplateSpec.volumes` array to declare the volumes for the Cassandra pods, and we use the `podTemplateSpec.containers.volumeMounts` array to describe where and how to mount them.

The `config.cassandra-yaml` field is where most of the encryption configuration happens, and we are using it to enable both internode and client-server encryption, which both use the same keystore and truststore for simplicity. **Remember that using internode encryption means your DC needs to go offline briefly for a full restart when the CA's keys rotate.**

* We are not using authz/n in this case to keep things simple. Don't do this in production.
* For both encryption types we need to specify (1) the keystore location, (2) the truststore location and (3) the passwords for the keystores. The locations of the keystore/truststore come from where we mounted them in `volumeMounts`.
* We are specifying JVM options just to make this run politely on a smaller machine. You would tune this for a production deployment.

Roll out the cass-operator and the CassandraDatacenter using `kubectl apply -k manifests/cass-operator`. Because the CRDs might take a moment to propagate, there is a chance you'll see errors stating that the resource type does not exist. Just keep re-applying until everything works - this is a declarative system so applying the same manifests multiple times is an idempotent operation.

### Reaper deployment

The k8ssandra project offers a Reaper operator, but for simplicity we are using a simple deployment (because not every deployment needs an operator). The deployment is standard kubernetes fare, and if you want more information on how these work you should refer to the Kubernetes [docs](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/). 

We are injecting the keystore and truststore passwords into the environment here, to avoid placing them in the manifests. The cass-operator does not currently support this approach without an initContainer to pre-process the cassandra.yaml using `envsubst` or a similar tool.

The only other note is that we are also pulling down a Cassandra image and using it in an initContainer to create a keyspace for Reaper, if it does not exist. In this container, we are also adding a `~/.cassandra/cqlshrc` file under the home directory. This provides SSL connectivity configurations for the container. The critical part of the `cqlshrc` file that we are adding is:

```
[ssl]
certfile = /crypto/ca.crt
validate = true
userkey = /crypto/tls.key
usercert = /crypto/tls.crt
version = TLSv1_2
```

The `version = TLSv1_2` tripped me up a few times, as it seems to be a recent requirement. Failing to add this line will give you back the rather fierce `Last error: [SSL] internal error` in the initContainer.
The commands run in this container are not ideal. In particular, the fact that we are sleeping for 840 seconds to wait for Cassandra to start is sloppy. In a real deployment we'd want to health check and wait until the Cassandra service became available.

Apply the manifests using `kubectl apply -k manifests/reaper`.

# Results

If you use a GUI, look at the logs for Reaper, you should see that it has connected to the cluster and provided some nice ASCII art to your console.

If you don't use a GUI, you can run `kubectl get pods -n cass-operator` to find your Reaper pod (which we'll call `REAPER_PODNAME`) and then run `kubectl logs -n cass-operator REAPER_PODNAME` to pull the logs.

# Conclusion

While the above might seem like a complex procedure, we've just created a Cassandra cluster with both client-server and internode encryption enabled, all of the required certs, and a Reaper deployment which is configured to connect using the correct certs. Not bad.

Do keep in mind the weaknesses relating to key rotation, and watch this space for progress on that front.