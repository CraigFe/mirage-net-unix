.PHONY: all clean install build
all: build doc

NAME    = $(shell grep 'Name:' _oasis    | sed 's/Name: *//')
VERSION = $(shell grep 'Version:' _oasis | sed 's/Version: *//')
J=4

export OCAMLRUNPARAM=b

setup.bin: setup.ml
	@ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	@rm -f setup.cmx setup.cmi setup.o setup.cmo

setup.data: setup.bin
	@./setup.bin -configure $(CONFIGUREFLAGS)

build: setup.data setup.bin
	@./setup.bin -build -j $(J)

doc: setup.data setup.bin
	@./setup.bin -doc -j $(J)

install: setup.bin
	@./setup.bin -install

uninstall:
	@ocamlfind remove $(NAME) || true

test: setup.bin
	@./setup.bin -configure --enable-tests
	@./setup.bin -build -j $(J)
	@./setup.bin -test

reinstall: setup.bin
	@ocamlfind remove $(NAME) || true
	@./setup.bin -reinstall

clean:
	@ocamlbuild -clean
	@rm -f setup.data setup.log setup.bin

ARCHIVE = https://github.com/mirage/mirage-net-unix/archive/v$(VERSION).tar.gz

release:
	git tag -a v$(VERSION) -m "Version $(VERSION)."
	git push upstream v$(VERSION)
	$(MAKE) pr

pr:
	opam publish prepare $(NAME).$(VERSION) $(ARCHIVE)
	OPAMYES=1 opam publish submit $(NAME).$(VERSION) && rm -rf $(NAME).$(VERSION)
