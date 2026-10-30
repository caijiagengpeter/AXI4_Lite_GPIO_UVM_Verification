`timescale 1ns/1ps
`default_nettype none

module axi4l_gpio_sva #(
  parameter int ADDR_WIDTH = 5,
  parameter int DATA_WIDTH = 32,
  parameter int NOUT = 30,
  parameter int NIN = 5,
  parameter bit [NOUT-1:0] DEFAULT_OUTPUT = '0
) (
  input wire                  clk,
  input wire                  reset_n,
  input wire [ADDR_WIDTH-1:0] awaddr,
  input wire [2:0]            awprot,
  input wire                  awvalid,
  input wire                  awready,
  input wire [DATA_WIDTH-1:0] wdata,
  input wire [DATA_WIDTH/8-1:0] wstrb,
  input wire                  wvalid,
  input wire                  wready,
  input wire [1:0]            bresp,
  input wire                  bvalid,
  input wire                  bready,
  input wire [ADDR_WIDTH-1:0] araddr,
  input wire [2:0]            arprot,
  input wire                  arvalid,
  input wire                  arready,
  input wire [DATA_WIDTH-1:0] rdata,
  input wire [1:0]            rresp,
  input wire                  rvalid,
  input wire                  rready,
  input wire [NIN-1:0]        i_gpio,
  input wire [NOUT-1:0]       o_gpio,
  input wire                  o_int,
  input wire                  write_accept,
  input wire [2:0]            write_word_addr,
  input wire [DATA_WIDTH-1:0] write_data,
  input wire [DATA_WIDTH/8-1:0] write_strb,
  input wire                  read_accept,
  input wire [NIN-1:0]        q_gpio,
  input wire [NIN-1:0]        qq_gpio,
  input wire [NIN-1:0]        last_gpio,
  input wire [NIN-1:0]        changed,
  input wire [NIN-1:0]        mask
);

  localparam bit [2:0] ADDR_INDATA  = 3'd4;
  localparam bit [2:0] ADDR_CHANGED = 3'd5;
  localparam bit [2:0] ADDR_MASK    = 3'd6;
  localparam bit [2:0] ADDR_INT     = 3'd7;

  // AXI source obligations: VALID and payload remain stable until READY.
  a_aw_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      awvalid && !awready |=> awvalid && $stable({awaddr, awprot}));

  a_w_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      wvalid && !wready |=> wvalid && $stable({wdata, wstrb}));

  a_ar_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      arvalid && !arready |=> arvalid && $stable({araddr, arprot}));

  a_b_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      bvalid && !bready |=> bvalid && $stable(bresp));

  a_r_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      rvalid && !rready |=> rvalid && $stable({rdata, rresp}));

  // Each internally accepted request produces a response on the next cycle.
  // A completed response may be replaced without dropping VALID.
  a_write_accept_sets_bvalid: assert property (
    @(posedge clk) disable iff (!reset_n) write_accept |=> bvalid);

  a_read_accept_sets_rvalid: assert property (
    @(posedge clk) disable iff (!reset_n) read_accept |=> rvalid);

  a_bvalid_rise_has_write: assert property (
    @(posedge clk) disable iff (!reset_n) $rose(bvalid) |-> $past(write_accept));

  a_rvalid_rise_has_read: assert property (
    @(posedge clk) disable iff (!reset_n) $rose(rvalid) |-> $past(read_accept));

  a_bvalid_clears_after_handshake: assert property (
    @(posedge clk) disable iff (!reset_n)
      bvalid && bready && !write_accept |=> !bvalid);

  a_rvalid_clears_after_handshake: assert property (
    @(posedge clk) disable iff (!reset_n)
      rvalid && rready && !read_accept |=> !rvalid);

  a_bresp_is_okay: assert property (
    @(posedge clk) disable iff (!reset_n) bvalid |-> bresp == 2'b00);

  a_rresp_is_okay: assert property (
    @(posedge clk) disable iff (!reset_n) rvalid |-> rresp == 2'b00);

  // Synchronous reset state.  The implication deliberately checks the
  // registered result on the following sampled edge.
  a_reset_clears_channels_and_outputs: assert property (
    @(posedge clk) !reset_n |=>
      !bvalid && !rvalid && o_gpio == DEFAULT_OUTPUT && !o_int);

  a_reset_clears_gpio_input_state: assert property (
    @(posedge clk) !reset_n |=>
      q_gpio == '0 && qq_gpio == '0 && last_gpio == '0 &&
      changed == '0 && mask == '0);

  // This verifies the digital two-flop sampling pipeline only.  It makes no
  // claim about analog metastability behavior or MTBF.
  a_q_samples_input: assert property (
    @(posedge clk) disable iff (!reset_n) 1'b1 |=> q_gpio == $past(i_gpio));

  a_qq_samples_q: assert property (
    @(posedge clk) disable iff (!reset_n) 1'b1 |=> qq_gpio == $past(q_gpio));

  a_last_samples_qq: assert property (
    @(posedge clk) disable iff (!reset_n) 1'b1 |=> last_gpio == $past(qq_gpio));

  // RTL polarity is intentionally preserved: mask=1 enables an interrupt.
  // o_int is registered from the prior cycle's mask and sticky state.
  a_int_registered_relation: assert property (
    @(posedge clk) disable iff (!reset_n)
      1'b1 |=> o_int == |($past(mask) & $past(changed)));

  // Constrain only the timing envelope of output side effects here.  The
  // scoreboard remains the owner of LOAD/SET/CLEAR/TOGGLE data semantics.
  a_output_change_follows_output_write: assert property (
    @(posedge clk) disable iff (!reset_n)
      $changed(o_gpio)
      |-> $past(write_accept && write_word_addr <= 3'd3));

  a_zero_strobe_output_write_has_no_effect: assert property (
    @(posedge clk) disable iff (!reset_n)
      write_accept && write_word_addr <= 3'd3 && write_strb == '0
      |=> $stable(o_gpio));

  // Writes to read-only INPUT/INT cannot alter software-controlled output
  // or mask state.  Synchronizer, sticky, and registered interrupt activity
  // remains free to progress independently on the same edge.
  a_read_only_write_no_output_effect: assert property (
    @(posedge clk) disable iff (!reset_n)
      write_accept &&
      (write_word_addr == ADDR_INDATA || write_word_addr == ADDR_INT)
      |=> $stable(o_gpio));

  a_read_only_write_no_mask_effect: assert property (
    @(posedge clk) disable iff (!reset_n)
      write_accept &&
      (write_word_addr == ADDR_INDATA || write_word_addr == ADDR_INT)
      |=> $stable(mask));

  generate for (genvar bit_index = 0; bit_index < NIN; bit_index++) begin : g_changed_sva
    a_hardware_change_sets_sticky: assert property (
      @(posedge clk) disable iff (!reset_n)
        (last_gpio[bit_index] ^ qq_gpio[bit_index])
        |=> changed[bit_index]);

    a_changed_holds_without_w1c: assert property (
      @(posedge clk) disable iff (!reset_n)
        changed[bit_index] &&
        !(write_accept && write_word_addr == ADDR_CHANGED &&
          write_strb[bit_index/8] && write_data[bit_index])
        |=> changed[bit_index]);

    a_w1c_clears_without_hardware_set: assert property (
      @(posedge clk) disable iff (!reset_n)
        write_accept && write_word_addr == ADDR_CHANGED &&
        write_strb[bit_index/8] && write_data[bit_index] &&
        !(last_gpio[bit_index] ^ qq_gpio[bit_index])
        |=> !changed[bit_index]);

    c_synchronized_rise: cover property (
      @(posedge clk) disable iff (!reset_n) $rose(qq_gpio[bit_index]));

    c_synchronized_fall: cover property (
      @(posedge clk) disable iff (!reset_n) $fell(qq_gpio[bit_index]));

    c_w1c_with_hardware_set: cover property (
      @(posedge clk) disable iff (!reset_n)
        write_accept && write_word_addr == ADDR_CHANGED &&
        write_strb[bit_index/8] && write_data[bit_index] &&
        (last_gpio[bit_index] ^ qq_gpio[bit_index]));
  end endgenerate

  // Activation coverage distinguishes an untested property from a passing
  // property whose antecedent was exercised.
  c_aw_handshake: cover property (
    @(posedge clk) disable iff (!reset_n) awvalid && awready);
  c_w_handshake: cover property (
    @(posedge clk) disable iff (!reset_n) wvalid && wready);
  c_ar_handshake: cover property (
    @(posedge clk) disable iff (!reset_n) arvalid && arready);
  c_b_handshake: cover property (
    @(posedge clk) disable iff (!reset_n) bvalid && bready);
  c_r_handshake: cover property (
    @(posedge clk) disable iff (!reset_n) rvalid && rready);

  c_aw_stall: cover property (
    @(posedge clk) disable iff (!reset_n) awvalid && !awready);
  c_w_stall: cover property (
    @(posedge clk) disable iff (!reset_n) wvalid && !wready);
  c_ar_stall: cover property (
    @(posedge clk) disable iff (!reset_n) arvalid && !arready);
  c_b_stall: cover property (
    @(posedge clk) disable iff (!reset_n) bvalid && !bready);
  c_r_stall: cover property (
    @(posedge clk) disable iff (!reset_n) rvalid && !rready);

  c_aw_before_w: cover property (
    @(posedge clk) disable iff (!reset_n)
      (awvalid && awready) && !(wvalid && wready)
      ##[1:8] (wvalid && wready));

  c_w_before_aw: cover property (
    @(posedge clk) disable iff (!reset_n)
      (wvalid && wready) && !(awvalid && awready)
      ##[1:8] (awvalid && awready));

  c_aw_w_same_cycle: cover property (
    @(posedge clk) disable iff (!reset_n)
      awvalid && awready && wvalid && wready);

  c_read_only_write: cover property (
    @(posedge clk) disable iff (!reset_n)
      write_accept &&
      (write_word_addr == ADDR_INDATA || write_word_addr == ADDR_INT));

  c_output_side_effect: cover property (
    @(posedge clk) disable iff (!reset_n)
      write_accept && write_word_addr <= 3'd3
      ##1 $changed(o_gpio));

  c_int_assert: cover property (
    @(posedge clk) disable iff (!reset_n) $rose(o_int));

  c_int_deassert: cover property (
    @(posedge clk) disable iff (!reset_n) $fell(o_int));

endmodule

`default_nettype wire
