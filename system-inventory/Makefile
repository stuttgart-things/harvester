D2_VERSION ?= 0.7.1
D3_VERSION ?= 7.9.0

.PHONY: gen diagram html check serve clean d2-install d3-install

gen:            ## D2-Quelle aus inventory.yaml erzeugen + Inventar pruefen
	python3 gen.py --strict

diagram: gen    ## SVG aus der D2-Quelle rendern
	d2 --pad 24 --theme 0 topology.d2 topology.svg
	@test "$$(grep -c foreignObject topology.svg || true)" -eq 0 \
	  || { echo "FEHLER: topology.svg enthaelt <foreignObject> - Labels pruefen"; exit 1; }

html: gen       ## interaktive D3-Seite nach site/index.html bauen
	python3 build_html.py

check: diagram  ## wie CI: pruefen, dass die eingecheckten Artefakte aktuell sind
	git diff --exit-code -- topology.d2 topology.svg \
	  || { echo "FEHLER: topology.d2/.svg sind veraltet - 'make diagram' und committen"; exit 1; }

serve: html     ## lokale Vorschau der D3-Seite
	@echo "http://127.0.0.1:8000"
	python3 -m http.server 8000 --directory site

d2-install:     ## d2 nach ~/.local/bin installieren
	curl -fsSL -o /tmp/d2.tgz \
	  https://github.com/d2lang/d2/releases/download/v$(D2_VERSION)/d2-v$(D2_VERSION)-linux-amd64.tar.gz
	tar -xzf /tmp/d2.tgz -C /tmp
	install -Dm755 /tmp/d2-v$(D2_VERSION)/bin/d2 $(HOME)/.local/bin/d2

d3-install:     ## d3-Bundle nach vendor/ holen (wird inline eingebettet)
	mkdir -p vendor
	cd vendor \
	  && npm pack d3@$(D3_VERSION) \
	  && tar -xzf d3-$(D3_VERSION).tgz \
	  && mv package/dist/d3.min.js d3.min.js \
	  && rm -rf package d3-$(D3_VERSION).tgz

clean:
	rm -f topology.d2 topology.svg
	rm -rf site
