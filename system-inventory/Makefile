D2_VERSION ?= 0.7.1

.PHONY: gen diagram serve build clean d2-install

gen:            ## Markdown + D2-Quelle aus inventory.yaml erzeugen
	python3 tools/gen.py --strict

diagram: gen    ## SVG aus der D2-Quelle rendern
	d2 --pad 24 --theme 0 docs/topology.d2 docs/topology.svg

serve: diagram  ## Lokale Vorschau
	mkdocs serve

build: diagram  ## Statische Site nach ./site
	mkdocs build --strict

d2-install:     ## d2 nach ~/.local/bin installieren
	curl -fsSL -o /tmp/d2.tgz \
	  https://github.com/d2lang/d2/releases/download/v$(D2_VERSION)/d2-v$(D2_VERSION)-linux-amd64.tar.gz
	tar -xzf /tmp/d2.tgz -C /tmp
	install -Dm755 /tmp/d2-v$(D2_VERSION)/bin/d2 $(HOME)/.local/bin/d2

clean:
	rm -rf site docs/index.md docs/topology.d2 docs/topology.svg
