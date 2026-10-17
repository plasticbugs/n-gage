Put mycore.rom here.

Build it from your own MAME `mycore` romset with the builder in the release
zip, which needs nothing but Python 3:

    python3 mra_build.py mycore.mra mycore.zip

It reads the zip (or a directory of loose files) directly, checks every ROM's
CRC32, and verifies the finished image against a known md5, so
a wrong or damaged romset is reported rather than quietly built into
something that half works.

Already using pupdate or the standard `mra` tool? Point it at mycore.mra;
it is an ordinary MRA file.
