class axi4l_c3_4_dut_closure_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_c3_4_dut_closure_test)

  localparam int unsigned RESPONSE_HOLD_CYCLES = 12;

  function new(string name = "axi4l_c3_4_dut_closure_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    // Retire each sequence item once its request has been accepted so later
    // requests can legally fill the DUT skid entries while B/R is stalled.
    uvm_config_db#(bit)::set(this, "env.axi4l_agent.driver",
                             "limited_overlap_mode", 1'b1);
    super.build_phase(phase);
  endfunction

  task run_phase(uvm_phase phase);
    bit [GPIO_NIN-1:0] onehot_gpio;
    bit [31:0] onehot_data;
    int unsigned writes_before;
    int unsigned reads_before;
    int unsigned responses_before;
    int unsigned gpio_events_before;

    phase.raise_objection(this);
    writes_before      = env.scoreboard.write_checks;
    reads_before       = env.scoreboard.read_checks;
    responses_before   = env.scoreboard.response_checks;
    gpio_events_before = env.scoreboard.gpio_event_checks;

    // All four writes use legal byte-offset aliases.  Alternating address bit
    // one closes the only default axilgpio input toggle that C3.3 left
    // reachable.  The first B response is held so the following non-zero
    // WSTRB side effects pass through buffered/stalled AW and W paths.
    axi_write(5'h02, 32'h1357_9bdf, 4'b1111,
              0, 0, RESPONSE_HOLD_CYCLES);          // LOAD, bit1=1
    axi_write(5'h05, 32'h2468_ace0, 4'b0101,
              0, 3, 0);                             // SET, bit1=0, AW first
    axi_write(5'h0a, 32'h000f_f0f0, 4'b0011,
              3, 0, 0);                             // CLEAR, bit1=1, W first
    axi_write(5'h0d, 32'h00ff_00ff, 4'b1010,
              0, 0, 0);                             // TOGGLE, bit1=0
    env.axi_agent.driver.wait_for_limited_idle();

    // Hold the first R response and issue two more aliased reads.  The normal
    // monitor/scoreboard checks each returned value and the protocol SVA checks
    // held VALID/payload stability; coverage is therefore outcome-qualified.
    axi_read(5'h03, 0, RESPONSE_HOLD_CYCLES);
    axi_read(5'h06, 0, 0);
    axi_read(5'h0b, 0, 0);
    env.axi_agent.driver.wait_for_limited_idle();

    // Close the four outcome-qualified W1C matrix combinations left by C3.3:
    // zero/off with stable and changing input, zero/on/stable, and
    // one/off/changing.  The zero-strobe cases must preserve software state;
    // real synchronized input changes must still set CHANGED.
    onehot_gpio = '0;
    onehot_data = '0;
    onehot_gpio[0] = 1'b1;
    onehot_data[0] = 1'b1;
    gpio_level('0, 6);
    axi_write(5'h14, 32'hffff_ffff, 4'b0001);
    env.axi_agent.driver.wait_for_limited_idle();
    axi_write(5'h14, 32'h0000_0000, 4'b0000); // zero/off/stable
    axi_write(5'h14, 32'h0000_0000, 4'b0001); // zero/on/stable
    env.axi_agent.driver.wait_for_limited_idle();

    fork
      gpio_level(onehot_gpio, 6);
      axi_write(5'h14, 32'h0000_0000, 4'b0000, 3, 3, 1);
    join
    env.axi_agent.driver.wait_for_limited_idle(); // zero/off/changing

    gpio_level('0, 6);
    axi_write(5'h14, 32'hffff_ffff, 4'b0001);
    env.axi_agent.driver.wait_for_limited_idle();
    fork
      gpio_level(onehot_gpio, 6);
      axi_write(5'h14, onehot_data, 4'b0000, 3, 3, 1);
    join
    env.axi_agent.driver.wait_for_limited_idle(); // one/off/changing
    repeat (4) @(env.axi_agent.driver.vif.mon_cb);

    if ((env.scoreboard.write_checks - writes_before) < 4)
      `uvm_error("C3_4_DUT_WRITE_CHECK",
        $sformatf("only %0d/4 output writes were checker-validated",
          env.scoreboard.write_checks - writes_before))
    if ((env.scoreboard.read_checks - reads_before) < 3)
      `uvm_error("C3_4_DUT_READ_CHECK",
        $sformatf("only %0d/3 reads were checker-validated",
          env.scoreboard.read_checks - reads_before))
    if ((env.scoreboard.response_checks - responses_before) < 7)
      `uvm_error("C3_4_DUT_RESPONSE_CHECK",
        $sformatf("only %0d/7 responses were checker-validated",
          env.scoreboard.response_checks - responses_before))
    if ((env.scoreboard.gpio_event_checks - gpio_events_before) < 4)
      `uvm_error("C3_4_DUT_GPIO_CHECK",
        $sformatf("only %0d/4 GPIO side effects were checker-validated",
          env.scoreboard.gpio_event_checks - gpio_events_before))
    if (env.scoreboard.error_count != 0)
      `uvm_error("C3_4_DUT_SCOREBOARD",
        $sformatf("scoreboard recorded %0d errors", env.scoreboard.error_count))

    `uvm_info("C3_4_DUT_CLOSURE_PASS",
      $sformatf("checked writes=%0d reads=%0d responses=%0d gpio_events=%0d",
        env.scoreboard.write_checks - writes_before,
        env.scoreboard.read_checks - reads_before,
        env.scoreboard.response_checks - responses_before,
        env.scoreboard.gpio_event_checks - gpio_events_before), UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass

class axi4l_c3_4b_w1c_off_change_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_c3_4b_w1c_off_change_test)

  localparam bit [AXI4L_ADDR_WIDTH-1:0] ADDR_CHANGED = 5'h14;
  // The proven C2 collision schedule: the GPIO drive starts just after the
  // launch edge and q->qq->last detection occurs on the third sampled edge.
  // Two driver clocking-block delays make the real WRITE_COMMIT occur there.
  localparam int unsigned COMMIT_ALIGN_DELAY = 2;

  function new(string name = "axi4l_c3_4b_w1c_off_change_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task automatic clear_changed(bit [GPIO_NIN-1:0] clear_mask);
    bit [AXI4L_DATA_WIDTH-1:0] clear_data;
    clear_data = '0;
    for (int bit_index = 0; bit_index < GPIO_NIN; bit_index++)
      clear_data[bit_index] = clear_mask[bit_index];
    axi_write(ADDR_CHANGED, clear_data, 4'b0001);
  endtask

  task automatic establish_clean_low(bit [GPIO_NIN-1:0] clear_mask);
    // A return-to-low transition is itself a legal hardware event.  Let it
    // traverse q/qq/last, then clear the resulting sticky bit while stable.
    gpio_level('0, 6);
    clear_changed(clear_mask);
    axi_read(ADDR_CHANGED);
  endtask

  task automatic exercise_off_change(bit data_one,
                                     int unsigned bit_index);
    bit [GPIO_NIN-1:0]         onehot_gpio;
    bit [AXI4L_DATA_WIDTH-1:0] write_data;

    onehot_gpio = '0;
    onehot_gpio[bit_index] = 1'b1;
    write_data = '0;
    if (data_one)
      write_data[bit_index] = 1'b1;

    establish_clean_low(onehot_gpio);
    fork
      gpio_level(onehot_gpio, 6);
      axi_write(ADDR_CHANGED, write_data, 4'b0000,
                COMMIT_ALIGN_DELAY, COMMIT_ALIGN_DELAY, 1);
    join

    // The independent cycle model consumes the external request plus the real
    // internal commit event, applies W1C before the same-edge hardware set, and
    // checks this read.  No DUT internal state is used as expected data.
    axi_read(ADDR_CHANGED);
    `uvm_info("C3_4B_W1C_OFF_CHANGE",
      $sformatf("checked data=%0b/WSTRB=off with same-commit hardware change on bit%0d",
                data_one, bit_index), UVM_NONE)
  endtask

  task run_phase(uvm_phase phase);
    int unsigned reads_before;
    int unsigned responses_before;
    longint unsigned commits_before;

    phase.raise_objection(this);
    reads_before     = env.scoreboard.read_checks;
    responses_before = env.scoreboard.response_checks;
    commits_before   = env.timing_monitor.write_commit_count;

    exercise_off_change(1'b0, 0);
    exercise_off_change(1'b1, (GPIO_NIN > 1) ? 1 : 0);
    repeat (4) @(env.axi_agent.driver.vif.mon_cb);

    if ((env.scoreboard.read_checks - reads_before) < 4)
      `uvm_error("C3_4B_W1C_READ_CHECK",
        $sformatf("only %0d/4 CHANGED reads were checker-validated",
                  env.scoreboard.read_checks - reads_before))
    if ((env.scoreboard.response_checks - responses_before) < 8)
      `uvm_error("C3_4B_W1C_RESPONSE_CHECK",
        $sformatf("only %0d/8 responses were checker-validated",
                  env.scoreboard.response_checks - responses_before))
    if ((env.timing_monitor.write_commit_count - commits_before) < 4)
      `uvm_error("C3_4B_W1C_COMMIT_CHECK",
        $sformatf("only %0d/4 writes reached real internal commit",
                  env.timing_monitor.write_commit_count - commits_before))
    if (env.scoreboard.error_count != 0)
      `uvm_error("C3_4B_W1C_SCOREBOARD",
        $sformatf("scoreboard recorded %0d errors", env.scoreboard.error_count))

    `uvm_info("C3_4B_W1C_CLOSURE_PASS",
      "data=0/1 x WSTRB-off x same-commit hardware-change were independently checked",
      UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass


class axi4l_c3_4_v4_payload_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_c3_4_v4_payload_seq)

  localparam int unsigned NUM_PER_DIRECTION = 32;
  axi4l_seq_item write_req[$];
  axi4l_seq_item read_req[$];
  int unsigned failure_count;

  covergroup verified_payload_cg with function sample(
    bit is_write,
    bit [AXI4L_ADDR_WIDTH-1:0] addr,
    bit [AXI4L_DATA_WIDTH-1:0] data,
    bit [AXI4L_DATA_WIDTH/8-1:0] strb,
    bit [2:0] prot
  );
    option.per_instance = 1;
    cp_access: coverpoint is_write {
      bins read = {0}; bins write = {1};
    }
    cp_addr: coverpoint addr {
      bins zero = {'0};
      bins all_ones = {{AXI4L_ADDR_WIDTH{1'b1}}};
      bins middle[] = {[1:(1<<AXI4L_ADDR_WIDTH)-2]};
    }
    cp_data: coverpoint data iff (is_write) {
      bins zero = {'0}; bins ones = {'1};
      bins alternating_a = {32'haaaa_aaaa};
      bins alternating_5 = {32'h5555_5555};
    }
    cp_strb: coverpoint strb iff (is_write) {
      bins zero = {'0}; bins ones = {'1};
      bins alternating_a = {4'ha}; bins alternating_5 = {4'h5};
    }
    cp_prot: coverpoint prot { bins values[] = {[0:7]}; }
    access_x_addr: cross cp_access, cp_addr;
  endgroup

  function new(string name = "axi4l_c3_4_v4_payload_seq");
    super.new(name);
    verified_payload_cg = new;
    failure_count = 0;
  endfunction

  function automatic bit [31:0] write_pattern(int unsigned index);
    case (index % 4)
      0: return 32'h0000_0000;
      1: return 32'hffff_ffff;
      2: return 32'haaaa_aaaa;
      default: return 32'h5555_5555;
    endcase
  endfunction

  function automatic bit [3:0] strobe_pattern(int unsigned index);
    case (index % 4)
      0: return 4'h0;
      1: return 4'hf;
      2: return 4'ha;
      default: return 4'h5;
    endcase
  endfunction

  task automatic issue_write(int unsigned index);
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create($sformatf("c3_4_v4_wr_%0d", index));
    start_item(req);
    req.access = AXI4L_WRITE;
    req.addr   = index[AXI4L_ADDR_WIDTH-1:0];
    req.data   = write_pattern(index);
    req.strb   = strobe_pattern(index);
    req.prot   = index[2:0];
    req.aw_delay = (index % 5 == 1) ? 3 : 0;
    req.w_delay  = (index % 7 == 2) ? 4 : 0;
    req.bready_delay = (index < 8) ? 16 : (index % 3);
    req.ar_delay = 0;
    req.rready_delay = 0;
    req.set_transaction_id(1000 + index);
    write_req.push_back(req);
    finish_item(req);
  endtask

  task automatic issue_read(int unsigned index);
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create($sformatf("c3_4_v4_rd_%0d", index));
    start_item(req);
    req.access = AXI4L_READ;
    req.addr   = AXI4L_ADDR_WIDTH'(NUM_PER_DIRECTION - 1 - index);
    req.data   = '0;
    req.strb   = '0;
    req.prot   = ~index[2:0];
    req.aw_delay = 0;
    req.w_delay  = 0;
    req.bready_delay = 0;
    req.ar_delay = (index % 6 == 3) ? 2 : 0;
    req.rready_delay = (index < 8) ? 16 : (index % 3);
    req.set_transaction_id(2000 + index);
    read_req.push_back(req);
    finish_item(req);
  endtask

  task body();
    axi4l_seq_item rsp;
    longint unsigned last_write_cycle;
    longint unsigned last_read_cycle;
    bit response_ok;

    set_response_queue_depth(-1);
    last_write_cycle = 0;
    last_read_cycle  = 0;

    for (int i = 0; i < NUM_PER_DIRECTION; i++)
      issue_write(i);
    for (int i = 0; i < NUM_PER_DIRECTION; i++)
      issue_read(i);

    for (int i = 0; i < NUM_PER_DIRECTION; i++) begin
      get_response(rsp, write_req[i].get_transaction_id());
      response_ok = !rsp.transaction_aborted && (rsp.resp === 2'b00) &&
                    (rsp.addr == write_req[i].addr) &&
                    (rsp.data == write_req[i].data) &&
                    (rsp.strb == write_req[i].strb);
      if (!response_ok) begin
        failure_count++;
        `uvm_error("C3_4_V4_WRITE_CHECK",
          $sformatf("write[%0d] response/payload association failed", i))
      end else
        verified_payload_cg.sample(1'b1, rsp.addr, rsp.data, rsp.strb,
                                   rsp.prot);
      if ((i != 0) && (rsp.response_cycle <= last_write_cycle)) begin
        failure_count++;
        `uvm_error("C3_4_V4_WRITE_ORDER", "write response order regressed")
      end
      last_write_cycle = rsp.response_cycle;
    end

    for (int i = 0; i < NUM_PER_DIRECTION; i++) begin
      get_response(rsp, read_req[i].get_transaction_id());
      response_ok = !rsp.transaction_aborted && (rsp.resp === 2'b00) &&
                    (rsp.addr == read_req[i].addr) &&
                    (rsp.rdata ===
                      ({{(AXI4L_DATA_WIDTH-AXI4L_ADDR_WIDTH){1'b0}}, rsp.addr}
                       ^ 32'h5a5a_1000));
      if (!response_ok) begin
        failure_count++;
        `uvm_error("C3_4_V4_READ_CHECK",
          $sformatf("read[%0d] response/data association failed", i))
      end else
        verified_payload_cg.sample(1'b0, rsp.addr, rsp.rdata, '0, rsp.prot);
      if ((i != 0) && (rsp.response_cycle <= last_read_cycle)) begin
        failure_count++;
        `uvm_error("C3_4_V4_READ_ORDER", "read response order regressed")
      end
      last_read_cycle = rsp.response_cycle;
    end
  endtask
endclass


class axi4l_c3_4_v4_payload_test extends axi4l_v4_agent_test_base;
  `uvm_component_utils(axi4l_c3_4_v4_payload_test)

  function new(string name = "axi4l_c3_4_v4_payload_test",
               uvm_component parent = null);
    super.new(name, parent);
    configured_depth = 8;
  endfunction

  task run_phase(uvm_phase phase);
    axi4l_c3_4_v4_payload_seq seq;
    bit stop;
    int unsigned stalls;
    int unsigned test_failures;

    phase.raise_objection(this);
    wait_for_startup();
    seq = axi4l_c3_4_v4_payload_seq::type_id::create("seq");
    stop = 1'b0;
    test_failures = 0;
    fork
      check_stability(stop, stalls);
      begin
        seq.start(agent.sequencer);
        agent.driver.wait_for_v4_idle();
        stop = 1'b1;
      end
    join

    if (stalls == 0) begin
      test_failures++;
      `uvm_error("C3_4_V4_NO_STALL", "payload suite observed no legal stall")
    end
    if ((agent.driver.v4_dispatch_count != 64) ||
        (agent.driver.v4_publish_count != 64) ||
        (agent.driver.v4_b_handshake_count != 32) ||
        (agent.driver.v4_r_handshake_count != 32)) begin
      test_failures++;
      `uvm_error("C3_4_V4_EXACTLY_ONCE",
        $sformatf("dispatch/publish/B/R=%0d/%0d/%0d/%0d expected 64/64/32/32",
          agent.driver.v4_dispatch_count, agent.driver.v4_publish_count,
          agent.driver.v4_b_handshake_count, agent.driver.v4_r_handshake_count))
    end
    if ((vif.test_max_write_outstanding < 8) ||
        (vif.test_max_read_outstanding < 8)) begin
      test_failures++;
      `uvm_error("C3_4_V4_DEPTH",
        $sformatf("payload suite reached only write/read depth %0d/%0d",
          vif.test_max_write_outstanding, vif.test_max_read_outstanding))
    end

    if ((seq.failure_count == 0) && (test_failures == 0))
      `uvm_info("C3_4_V4_PAYLOAD_PASS",
        $sformatf("64 checked responses, actual depth write/read=%0d/%0d stalls=%0d",
          vif.test_max_write_outstanding, vif.test_max_read_outstanding, stalls),
        UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
