CONTEXT_SITE_B ?= site-b
NS_RHSI ?= rhsi

.PHONY: apply-standby check-standby clean-standby

apply-standby:
	oc --context $(CONTEXT_SITE_B) apply -f rhsi-external-secrets-operator/
	oc --context $(CONTEXT_SITE_B) apply -f rhsi/standby/

check-standby:
	oc --context $(CONTEXT_SITE_B) -n $(NS_RHSI) get ns || true
	oc --context $(CONTEXT_SITE_B) -n $(NS_RHSI) get secretstore,externalsecret || true
	oc --context $(CONTEXT_SITE_B) -n $(NS_RHSI) get job,pod || true

clean-standby:
	oc --context $(CONTEXT_SITE_B) delete -f rhsi/standby/ || true
	oc --context $(CONTEXT_SITE_B) delete -f rhsi-external-secrets-operator/ || true
