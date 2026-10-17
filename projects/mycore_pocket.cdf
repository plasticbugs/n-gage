JedecChain;
  FileRevision(JESD32A);
  DefaultMfr(6E);

  P ActionCode(Cfg)
    Device PartName(5CEBA4F23C8) Path("output_files/") File("mycore_pocket.sof") MfrSpec(OpMask(1));
ChainEnd;

AlteraBegin;
  ChainType(JTAG);
AlteraEnd;
