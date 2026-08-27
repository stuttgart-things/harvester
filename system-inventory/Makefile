D2_VERSION ?= 0.7.1
D3_VERSION ?= 7.9.0
# GitHub-hosted runners ship Chrome at this name. Locally, point CHROME at
# whatever headless Chromium you have.
CHROME ?= google-chrome

.PHONY: gen diagram html pdf check serve clean d2-install d3-install

gen:            ## generate the D2 source from inventory.yaml + validate
	python3 gen.py --strict

diagram: gen    ## render the SVG from the D2 source
	d2 --pad 24 --theme 0 topology.d2 topology.svg
	@test "$$(grep -c foreignObject topology.svg || true)" -eq 0 \
	  || { echo "ERROR: topology.svg contains <foreignObject> - check the labels"; exit 1; }

html: gen       ## build the interactive D3 page into site/index.html
	python3 build_html.py

pdf: html       ## render site/inventory.pdf with headless Chrome
	@command -v $(CHROME) >/dev/null 2>&1 || { \
	  echo "ERROR: '$(CHROME)' not found. Set CHROME to a headless Chromium," ; \
	  echo "       e.g. CHROME=chromium make pdf"; exit 1; }
	$(CHROME) --headless=new --disable-gpu --no-sandbox \
	  --virtual-time-budget=20000 \
	  --run-all-compositor-stages-before-draw \
	  --no-pdf-header-footer \
	  --print-to-pdf="$(CURDIR)/site/inventory.pdf" \
	  "file://$(CURDIR)/site/index.html?print=1"
	@test -s site/inventory.pdf || { echo "ERROR: no PDF produced"; exit 1; }
	@echo "wrote: site/inventory.pdf ($$(du -k site/inventory.pdf | cut -f1) KB)"

check: diagram  ## like CI: verify the committed artifacts are up to date
	git diff --exit-code -- topology.d2 topology.svg \
	  || { echo "ERROR: topology.d2/.svg are stale - run 'make diagram' and commit"; exit 1; }

serve: html     ## local preview of the D3 page
	@echo "http://127.0.0.1:8000"
	python3 -m http.server 8000 --directory site

d2-install:     ## install d2 into ~/.local/bin
	curl -fsSL -o /tmp/d2.tgz \
	  https://github.com/d2lang/d2/releases/download/v$(D2_VERSION)/d2-v$(D2_VERSION)-linux-amd64.tar.gz
	tar -xzf /tmp/d2.tgz -C /tmp
	install -Dm755 /tmp/d2-v$(D2_VERSION)/bin/d2 $(HOME)/.local/bin/d2

d3-install:     ## fetch the d3 bundle into vendor/ (gets inlined into the page)
	mkdir -p vendor
	cd vendor \
	  && npm pack d3@$(D3_VERSION) \
	  && tar -xzf d3-$(D3_VERSION).tgz \
	  && mv package/dist/d3.min.js d3.min.js \
	  && rm -rf package d3-$(D3_VERSION).tgz

clean:
	rm -f topology.d2 topology.svg
	rm -rf site
