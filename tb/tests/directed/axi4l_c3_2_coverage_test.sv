class axi4l_c3_2_coverage_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_c3_2_coverage_test)

  function new(string name = "axi4l_c3_2_coverage_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task automatic relation_delays(int relation,
                                 output int unsigned aw_delay,
                                 output int unsigned w_delay);
    aw_delay = 0;
    w_delay = 0;
    case (relation)
      1: w_delay = 1;
      2: w_delay = 3;
      3: w_delay = 6;
      4: w_delay = 9;
      5: aw_delay = 1;
      6: aw_delay = 3;
      7: aw_delay = 6;
      8: aw_delay = 9;
      default: ;
    endcase
  endtask

  task run_phase(uvm_phase phase);
    int unsigned legal_regs[6] = '{0, 1, 2, 3, 5, 6};
    int unsigned aw_delay;
    int unsigned w_delay;
    int unsigned relation;
    int unsigned response_delay;
    bit [AXI4L_DATA_WIDTH-1:0] data;
    bit [AXI4L_DATA_WIDTH/8-1:0] strb;
    bit [AXI4L_ADDR_WIDTH-1:0] addr;

    phase.raise_objection(this);
    gpio_level('0, 6);

    // Six architecturally writable registers x all sixteen WSTRB values.
    // Every operation completes through the normal monitor/C2/scoreboard
    // path.  Non-zero data is retained even for WSTRB=0, proving no-effect
    // behavior rather than using zero data to avoid a side effect.
    foreach (legal_regs[reg_index]) begin
      addr = legal_regs[reg_index] * 4;
      for (int unsigned pattern = 0; pattern < 16; pattern++) begin
        strb = pattern[AXI4L_DATA_WIDTH/8-1:0];
        data = 32'h5aa5_00f0 ^ (32'h0101_0101 * pattern)
                             ^ (32'h1111_0000 * legal_regs[reg_index]);
        data[GPIO_NIN-1:0] = (pattern + legal_regs[reg_index] + 1);
        relation = (pattern + reg_index) % 9;
        relation_delays(relation, aw_delay, w_delay);
        response_delay = ((pattern + reg_index) & 1) ? 0 : 6;
        axi_write(addr, data, strb, aw_delay, w_delay, response_delay);
        axi_read(addr, 0, (pattern & 1));
      end
    end

    // Exercise observed MASK/IRQ assertion and deassertion after the matrix.
    axi_write(5'h18, 32'h0000_0001, 4'b0001, 0, 0, 4);
    gpio_level(5'b00001, 6);
    axi_read(5'h1c);
    axi_write(5'h14, 32'h0000_0001, 4'b0001, 2, 0, 4);
    gpio_level('0, 6);
    axi_read(5'h1c);

    `uvm_info("C3_2_CLOSURE_PASS",
      "scoreboard-checked 6-register x 16-WSTRB matrix and IRQ event path completed",
      UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass

class axi4l_c3_2_timing_seq extends axi4l_c2_directed_seq;
  `uvm_object_utils(axi4l_c3_2_timing_seq)

  function new(string name = "axi4l_c3_2_timing_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned transaction_id = 300;
    int unsigned delays[3] = '{1, 3, 6};
    set_response_queue_depth(-1);

    // A leading response occupies the single DUT response slot.  The second
    // accepted request is still checked by the existing C2 monitor and
    // scoreboard when its real commit/snapshot occurs after 1/short/moderate
    // backpressure intervals.
    foreach (delays[index]) begin
      issue_request(AXI4L_WRITE, transaction_id++, 5'h10,
                    32'hc300_0000 | index, 4'b1111, delays[index]);
      issue_request(AXI4L_WRITE, transaction_id++, 5'h04,
                    32'h0000_0001 << index, 4'b0001);
      expect_response(transaction_id - 2, 1'b0);
      expect_response(transaction_id - 1, 1'b0);

      issue_request(AXI4L_READ, transaction_id++, 5'h00,
                    '0, '1, 0, delays[index]);
      issue_request(AXI4L_READ, transaction_id++, 5'h00);
      expect_response(transaction_id - 2, 1'b0);
      expect_response(transaction_id - 1, 1'b0);
    end
  endtask
endclass

class axi4l_c3_2_timing_closure_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_c3_2_timing_closure_test)

  function new(string name = "axi4l_c3_2_timing_closure_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    uvm_config_db#(bit)::set(this, "env.axi4l_agent.driver", "v4_mode", 1'b1);
    uvm_config_db#(int unsigned)::set(
      this, "env.axi4l_agent.driver", "max_write_outstanding", 4);
    uvm_config_db#(int unsigned)::set(
      this, "env.axi4l_agent.driver", "max_read_outstanding", 4);
    super.build_phase(phase);
  endfunction

  task run_phase(uvm_phase phase);
    axi4l_c3_2_timing_seq seq;
    phase.raise_objection(this);
    seq = axi4l_c3_2_timing_seq::type_id::create("timing_closure_seq");
    seq.start(env.axi_agent.sequencer);
    env.axi_agent.driver.wait_for_v4_idle();
    repeat (4) @(env.axi_agent.driver.vif.mon_cb);
    `uvm_info("C3_2_TIMING_CLOSURE_PASS",
      "scoreboard-checked response-slot blocking scenarios completed", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass

class axi4l_c3_2_reset_context_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_c3_2_reset_context_test)

  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;

  function new(string name = "axi4l_c3_2_reset_context_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task automatic pulse_reset();
    vif.ARESETN <= 1'b0;
    repeat (3) @(vif.mon_cb);
    vif.ARESETN <= 1'b1;
    do @(vif.mon_cb); while (vif.mon_cb.ARESETN !== 1'b1);
    repeat (2) @(vif.mon_cb);
  endtask

  task automatic run_write_reset(bit w_only);
    axi4l_single_access_seq seq;
    bit trigger_seen;
    seq = axi4l_single_access_seq::type_id::create(
      w_only ? "w_only_seq" : "accepted_write_seq");
    seq.access = AXI4L_WRITE;
    seq.addr = 5'h00;
    seq.data = w_only ? 32'h0000_00a5 : 32'h0000_005a;
    seq.strb = 4'b0001;
    seq.aw_delay = w_only ? 12 : 0;
    seq.w_delay = 0;
    seq.response_delay = 0;
    fork
      seq.start(env.axi_agent.sequencer);
      begin
        forever begin
          @(vif.mon_cb);
          if (vif.mon_cb.ARESETN === 1'b1 &&
              vif.mon_cb.WVALID && vif.mon_cb.WREADY &&
              (w_only || (vif.mon_cb.AWVALID && vif.mon_cb.AWREADY))) begin
            trigger_seen = 1'b1;
            pulse_reset();
            break;
          end
        end
      end
    join
    if (!trigger_seen)
      `uvm_error("C3_2_RESET_TRIGGER", "write reset trigger was not observed")
  endtask

  task automatic run_read_reset();
    axi4l_single_access_seq seq;
    bit trigger_seen;
    seq = axi4l_single_access_seq::type_id::create("accepted_read_seq");
    seq.access = AXI4L_READ;
    seq.addr = 5'h00;
    seq.ar_delay = 0;
    seq.response_delay = 0;
    fork
      seq.start(env.axi_agent.sequencer);
      begin
        forever begin
          @(vif.mon_cb);
          if (vif.mon_cb.ARESETN === 1'b1 &&
              vif.mon_cb.ARVALID && vif.mon_cb.ARREADY) begin
            trigger_seen = 1'b1;
            pulse_reset();
            break;
          end
        end
      end
    join
    if (!trigger_seen)
      `uvm_error("C3_2_RESET_TRIGGER", "read reset trigger was not observed")
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif = env.axi_agent.driver.vif;
    do @(vif.mon_cb); while (vif.mon_cb.ARESETN !== 1'b1);
    repeat (3) @(vif.mon_cb);
    run_write_reset(1'b1);
    run_write_reset(1'b0);
    run_read_reset();

    // A normal post-reset access is checked end-to-end after every abort
    // context has drained and the scoreboard has advanced its reset epoch.
    axi_write(5'h00, 32'h0000_003c, 4'b0001);
    axi_read(5'h00);
    `uvm_info("C3_2_RESET_CONTEXT_PASS",
      "observed W-only, accepted-write, and accepted-read reset entries with checked recovery",
      UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
