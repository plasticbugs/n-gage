Put three things here; none of them comes with the core.

  ngvm.bin   the core's kernel.  It is in the release zip: copy it here.
  sym.rom    your N-Gage's own firmware, dumped from your phone (about
             18 MB).  The core runs it; it is not included and cannot be.
  <game>.img a game's memory card, one file per game, built from the
             game's files with the builder in the release zip:

                 python3 mkdrive.py --from vcop.zip --out vcop.img

             It needs nothing but Python 3.  The names the game list
             expects are in Assets/ngage/plasticbugs.ngage/*.json; add a
             JSON there, naming its .img, for any other game.
