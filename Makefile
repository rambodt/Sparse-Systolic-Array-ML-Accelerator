# Top-level Makefile.
#
# The Hammer ASIC flow lives in asic/. These wrapper targets make the project
# usable from the repository root with the same commands as the ASIC directory.

.PHONY: syn par sim-rtl sim-syn-functional sim-par-functional drc lvs clean

ASIC_DIR := asic

syn par sim-rtl sim-syn-functional sim-par-functional drc lvs:
	$(MAKE) -C $(ASIC_DIR) $@

clean:
	$(MAKE) -C $(ASIC_DIR) clean
