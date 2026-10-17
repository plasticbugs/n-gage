Put ngage.rom here.

Build it from your own MAME `ngage` romset with the builder in the release
zip, which needs nothing but Python 3:

    python3 mra_build.py ngage.mra ngage.zip

It reads the zip (or a directory of loose files) directly, checks every ROM's
CRC32, and verifies the finished image against a known md5, so
a wrong or damaged romset is reported rather than quietly built into
something that half works.

Already using pupdate or the standard `mra` tool? Point it at ngage.mra;
it is an ordinary MRA file.
