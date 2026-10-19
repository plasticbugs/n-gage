//------------------------------------------------------------------------------
// The CPU's micro-operation: what decode (D) hands to execute (E).  An ARM
// instruction is one or more of these; Thumb instructions are expanded to
// their ARM equivalents first, so nothing past D knows Thumb exists.
//
// Registers are physical indices (arm_regs.sv): 0-14 the user bank, 16-30
// the banked copies, 31 a temporary no instruction can name.  PC is not a
// register here: a read of R15 is resolved in D to the instruction's address
// plus 8 (ARM) or 4 (Thumb), and a write of R15 is a redirect.
//
// A package, so it is listed before its users: tools/gen_qip.sh and
// sim/lint.sh put every *_pkg.sv first.
//------------------------------------------------------------------------------
`default_nettype none

package arm_pkg;

// kinds
localparam logic [3:0] K_NOP    = 4'd0;
localparam logic [3:0] K_ALU    = 4'd1;   // data processing, MOV/BL link, ADD for Thumb
localparam logic [3:0] K_MUL    = 4'd2;   // MUL/MLA
localparam logic [3:0] K_MULL   = 4'd3;   // UMULL/SMULL, and the first half of the accumulating forms
localparam logic [3:0] K_MULH   = 4'd4;   // second half of UMLAL/SMLAL: add RdHi:RdLo
localparam logic [3:0] K_LOAD   = 4'd5;
localparam logic [3:0] K_STORE  = 4'd6;
localparam logic [3:0] K_BRANCH = 4'd7;   // B/BL, Thumb B/BL: target in imm (or a + imm)
localparam logic [3:0] K_BX     = 4'd8;
localparam logic [3:0] K_MRS    = 4'd9;
localparam logic [3:0] K_MSR    = 4'd10;
localparam logic [3:0] K_EXC    = 4'd11;  // SWI, undefined, prefetch abort, IRQ

typedef struct packed {
    logic        valid;
    logic [31:0] pc;            // the instruction's own address
    logic        thumb;
    logic [31:0] instr;         // as fetched (Thumb in the low half), for traces
    logic        first, last;   // uop position: the instruction retires on last
    logic  [3:0] cond;
    logic  [3:0] kind;

    // operands, read in D; forwarded in E by index
    logic  [4:0] ra, rb, rc;    // Rn, Rm, Rs or store data
    logic        ra_rd, rb_rd, rc_rd;   // read from the register file
    logic [31:0] a, b, c;       // values (PC already substituted)
    logic [31:0] imm;           // immediate operand, offset or branch target
    logic        use_imm;       // operand 2 / offset is imm, not shifted b

    // shifter
    logic  [1:0] sh_typ;
    logic  [4:0] sh_amt;        // immediate amount
    logic        sh_reg;        // amount from c[7:0]
    logic        imm_rot;       // imm came from a rotation: C out is imm[31]

    // ALU
    logic  [3:0] alu_op;
    logic        setflags;

    // destinations
    logic        wa_en;  logic [4:0] wa;  logic wa_pc;  // A: Rd / loaded value / RdLo; wa_pc: R15
    logic        wb_en;  logic [4:0] wb;                // B: base write-back / RdHi

    // memory
    logic  [1:0] msize;         // 0 byte, 1 halfword, 2 word
    logic        msigned;
    logic        pre, up;       // pre-indexed; add the offset
    logic        lsm;           // LDM/STM element: address is the latched base + imm
    logic        lsm_latch;     // first element: latch the base (a) for the rest
    logic [31:0] lsm_wb;        // LDM/STM write-back offset from the base

    // PSRs
    logic        psr_spsr;      // MRS/MSR: the SPSR, not the CPSR
    logic  [3:0] msr_mask;      // MSR fields: f s x c
    logic        restore;       // CPSR <- SPSR (MOVS pc / LDM^ with pc)

    // multiply
    logic        mul_signed;
    logic        mul_acc;

    // exceptions (K_EXC)
    logic  [2:0] exc_vec;       // vector address / 4
    logic  [4:0] exc_mode;
    logic [31:0] exc_lr;        // value for the new mode's LR
    logic  [4:0] exc_lr_reg;    // physical index of that LR

    logic        irq;           // an injected IRQ (pc is the instruction it displaced)

    // branch prediction (arm_cpu.sv, F1).  The prediction belongs to the
    // instruction, so only its last uop carries p_taken; every uop carries
    // p_sp, so whichever one redirects can repair the return stack
    logic        p_taken;       // fetch predicted a taken branch here
    logic [31:0] p_next;        // ... to this address, with bit 0 the Thumb state
    logic        p_tagm;        // the BTB held this address, whatever its counter
    logic  [1:0] p_ctr;         // ... and that counter
    logic  [2:0] p_sp;          // the return stack's depth before this instruction
    logic        br_call;       // BL, Thumb BL: pushes the return stack when taken
    logic        br_ret;        // BX lr, MOV pc lr, LDM/POP with pc: pops it
} uop_t;

// BTB entry kinds
localparam logic [1:0] BK_PLAIN = 2'd0;
localparam logic [1:0] BK_CALL  = 2'd1;
localparam logic [1:0] BK_RET   = 2'd2;    // the target is the return stack's top

// modes
localparam logic [4:0] M_USR = 5'h10;
localparam logic [4:0] M_FIQ = 5'h11;
localparam logic [4:0] M_IRQ = 5'h12;
localparam logic [4:0] M_SVC = 5'h13;
localparam logic [4:0] M_ABT = 5'h17;
localparam logic [4:0] M_UND = 5'h1B;
localparam logic [4:0] M_SYS = 5'h1F;

// the physical register an ARM register number names in a mode
function automatic logic [4:0] phys(input logic [3:0] r, input logic [4:0] m);
    logic [4:0] p;
    p = {1'b0, r};
    if (r >= 4'd8 && r != 4'd15) begin
        if (m == M_FIQ) p = 5'd16 + {1'b0, r} - 5'd8;
        else if (r >= 4'd13) begin
            case (m)
                M_SVC: p = (r == 4'd13) ? 5'd23 : 5'd24;
                M_ABT: p = (r == 4'd13) ? 5'd25 : 5'd26;
                M_IRQ: p = (r == 4'd13) ? 5'd27 : 5'd28;
                M_UND: p = (r == 4'd13) ? 5'd29 : 5'd30;
                default: ;
            endcase
        end
    end
    return p;
endfunction

// which register-file port an operand is read from (arm_regs.sv)
localparam logic [2:0] SC_RS = 3'd0, SC_RD = 3'd1, SC_RM = 3'd2, SC_RN = 3'd3, SC_RL = 3'd4;

endpackage
