class axi4l_c2_directed_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_c2_directed_seq)

  bit reset_window_ready;
  bit reset_completed;
  longint unsigned reset_accept_target = 11;

  function new(string name = "axi4l_c2_directed_seq");
    super.new(name);
  endfunction

  task automatic issue_request(axi4l_access_e access,
                               int unsigned transaction_id,
                               bit [AXI4L_ADDR_WIDTH-1:0] addr,
                               bit [AXI4L_DATA_WIDTH-1:0] data = '0,
                               bit [AXI4L_DATA_WIDTH/8-1:0] strb = '1,
                               int unsigned bready_delay = 0,
                               int unsigned rready_delay = 0,
                               int unsigned aw_delay = 0,
                               int unsigned w_delay = 0,
                               int unsigned ar_delay = 0);
    axi4l_seq_item request;
    request = axi4l_seq_item::type_id::create(
      $sformatf("c2_req_%0d", transaction_id));
    start_item(request);
    request.access       = access;
    request.addr         = addr;
    request.data         = data;
    request.strb         = strb;
    request.prot         = transaction_id[2:0];
    request.aw_delay     = aw_delay;
    request.w_delay      = w_delay;
    request.ar_delay     = ar_delay;
    request.bready_delay = bready_delay;
    request.rready_delay = rready_delay;
    request.set_transaction_id(transaction_id);
    finish_item(request);
  endtask

  task automatic expect_response(int unsigned transaction_id,
                                 bit expect_abort,
                                 bit check_rdata = 1'b0,
                                 bit [AXI4L_DATA_WIDTH-1:0] expected_rdata = '0);
    axi4l_seq_item response;
    get_response(response, transaction_id);
    if (response.transaction_aborted != expect_abort)
      `uvm_error("C2_RESPONSE_ABORT",
        $sformatf("transaction %0d abort=%0b expected=%0b",
                  transaction_id, response.transaction_aborted, expect_abort))
    if (!expect_abort && (response.resp !== 2'b00))
      `uvm_error("C2_RESPONSE_STATUS",
        $sformatf("transaction %0d response=%02b expected OKAY",
                  transaction_id, response.resp))
    if (!expect_abort && check_rdata && (response.rdata !== expected_rdata))
      `uvm_error("C2_SEQUENCE_RDATA",
        $sformatf("transaction %0d RDATA=0x%08h expected=0x%08h",
                  transaction_id, response.rdata, expected_rdata))
  endtask

  task body();
    set_response_queue_depth(-1);

    // Establish a non-zero starting point.
    issue_request(AXI4L_WRITE, 100, 5'h00, 32'h0000_0010, 4'b0001);
    expect_response(100, 1'b0);

    // Put each non-zero side-effecting SET/CLEAR/TOGGLE behind a read-only
    // blocker whose B response is held.  This proves all three operations from
    // accepted skid-buffer state through their later real commit cycles.
    issue_request(AXI4L_WRITE, 101, 5'h10, 32'h1111_1111, 4'b1111, 8);
    issue_request(AXI4L_WRITE, 102, 5'h04, 32'h0000_0003, 4'b0001);
    expect_response(101, 1'b0);
    expect_response(102, 1'b0);

    issue_request(AXI4L_WRITE, 103, 5'h10, 32'h2222_2222, 4'b1111, 8);
    issue_request(AXI4L_WRITE, 104, 5'h08, 32'h0000_0010, 4'b0001);
    expect_response(103, 1'b0);
    expect_response(104, 1'b0);

    issue_request(AXI4L_WRITE, 105, 5'h10, 32'h3333_3333, 4'b1111, 8);
    issue_request(AXI4L_WRITE, 106, 5'h0c, 32'h0000_0005, 4'b0001);
    expect_response(105, 1'b0);
    expect_response(106, 1'b0);
    issue_request(AXI4L_READ, 107, 5'h00);
    expect_response(107, 1'b0, 1'b1, 32'h0000_0006);

    // AR for read 106 is accepted while read 105 holds RREADY low.  The write
    // commits in between; read 106 must snapshot the new value only when the R
    // slot becomes available, not at its earlier external AR handshake.
    issue_request(AXI4L_READ, 108, 5'h00, '0, '1, 0, 12);
    issue_request(AXI4L_READ, 109, 5'h00);
    issue_request(AXI4L_WRITE, 110, 5'h00, 32'h0000_0022, 4'b0001);
    expect_response(110, 1'b0);
    expect_response(108, 1'b0, 1'b1, 32'h0000_0006);
    expect_response(109, 1'b0, 1'b1, 32'h0000_0022);

    // With the v4 dispatcher both contexts are queued before the next edge.
    // AW/W and AR execute on the same edge.  The read sees old 0x22 and the
    // write becomes visible after the NBA update as 0x33.
    issue_request(AXI4L_WRITE, 111, 5'h00, 32'h0000_0033, 4'b0001,
                  0, 0, 1, 1, 0);
    issue_request(AXI4L_READ, 112, 5'h00);
    expect_response(111, 1'b0);
    expect_response(112, 1'b0, 1'b1, 32'h0000_0022);
    issue_request(AXI4L_READ, 113, 5'h00);
    expect_response(113, 1'b0, 1'b1, 32'h0000_0033);

    // The second write is accepted into the skid path while the first response
    // is backpressured.  The test owns reset timing and aborts both contexts.
    issue_request(AXI4L_WRITE, 114, 5'h10, 32'h4444_4444, 4'b1111, 50);
    issue_request(AXI4L_WRITE, 115, 5'h04, 32'h0000_0080, 4'b0001);
    reset_window_ready = 1'b1;
    wait (reset_completed);
    expect_response(114, 1'b1);
    expect_response(115, 1'b1);

    // Prove post-reset recovery and reset-model reinitialization.
    issue_request(AXI4L_WRITE, 116, 5'h00, 32'h0000_0044, 4'b0001);
    expect_response(116, 1'b0);
    issue_request(AXI4L_READ, 117, 5'h00);
    expect_response(117, 1'b0, 1'b1, 32'h0000_0044);
  endtask
endclass

class axi4l_c2_timing_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_c2_timing_test)

  function new(string name = "axi4l_c2_timing_test",
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
    axi4l_c2_directed_seq seq;
    virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;
    bit sequence_done;

    phase.raise_objection(this);
    vif = env.axi_agent.driver.vif;
    do @(vif.mon_cb); while (vif.mon_cb.ARESETN !== 1'b1);
    repeat (3) @(vif.mon_cb);
    seq = axi4l_c2_directed_seq::type_id::create("seq");

    fork
      begin
        seq.start(env.axi_agent.sequencer);
        sequence_done = 1'b1;
      end
      begin
        wait (seq.reset_window_ready);
        wait (env.timing_monitor.accepted_write_count >=
              seq.reset_accept_target);
        @(vif.drv_cb);
        vif.ARESETN <= 1'b0;
        repeat (3) @(vif.drv_cb);
        vif.ARESETN <= 1'b1;
        repeat (2) @(vif.drv_cb);
        seq.reset_completed = 1'b1;
      end
    join

    if (!sequence_done)
      `uvm_fatal("C2_SEQUENCE", "directed sequence did not complete")
    env.axi_agent.driver.wait_for_v4_idle();
    repeat (4) @(vif.mon_cb);

    if (!env.timing_monitor.whitebox_enable)
      `uvm_error("C2_NOT_WHITEBOX", "cycle-exact timing adapter was not active")
    if (env.timing_monitor.buffered_nonzero_side_effect_count < 3)
      `uvm_error("C2_NO_BUFFERED_SIDE_EFFECT",
                 "did not observe delayed non-zero SET, CLEAR, and TOGGLE commits")
    if ((env.timing_monitor.b_stall_cycles == 0) ||
        (env.timing_monitor.r_stall_cycles == 0))
      `uvm_error("C2_NO_BACKPRESSURE", "required B/R backpressure was not observed")
    if (env.timing_monitor.delayed_snapshot_count == 0)
      `uvm_error("C2_NO_DELAYED_SNAPSHOT", "no AR-to-snapshot delay was observed")
    if (env.timing_monitor.same_edge_rw_count == 0)
      `uvm_error("C2_NO_SAME_EDGE", "same-edge read snapshot/write commit was not observed")
    if (env.timing_monitor.reset_count == 0)
      `uvm_error("C2_NO_RESET", "reset-while-buffered scenario was not observed")

    `uvm_info("C2_CYCLE_EVIDENCE",
      $sformatf("buffered write accept=%0d commit=%0d; delayed read AR=%0d snapshot=%0d; same-edge read/write=%0d; Bstall=%0d Rstall=%0d resets=%0d",
                env.timing_monitor.evidence_buffer_accept_cycle,
                env.timing_monitor.evidence_buffer_commit_cycle,
                env.timing_monitor.evidence_delayed_ar_cycle,
                env.timing_monitor.evidence_delayed_snapshot_cycle,
                env.timing_monitor.evidence_same_edge_cycle,
                env.timing_monitor.b_stall_cycles,
                env.timing_monitor.r_stall_cycles,
                env.timing_monitor.reset_count), UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass

class axi4l_c2_checker_selftest extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_c2_checker_selftest)

  function new(string name = "axi4l_c2_checker_selftest",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    uvm_config_db#(bit)::set(this, "env.axi4l_agent.driver",
                             "limited_overlap_mode", 1'b1);
    uvm_config_db#(bit)::set(this, "env.timing_monitor",
                             "c2_selftest_mode", 1'b1);
    uvm_config_db#(bit)::set(this, "env.scoreboard",
                             "c2_selftest_mode", 1'b1);
    super.build_phase(phase);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    env.timing_monitor.inject_orphan_commit_once = 1'b1;
    env.timing_monitor.inject_stale_commit_once  = 1'b1;
    axi_write(5'h10, 32'h0101_0101, 4'b1111);
    env.axi_agent.driver.wait_for_limited_idle();

    env.timing_monitor.inject_duplicate_commit_once = 1'b1;
    axi_write(5'h10, 32'h0202_0202, 4'b1111);
    env.axi_agent.driver.wait_for_limited_idle();

    // Keep missing last so later commits cannot consume the intentionally
    // retained accepted request and shift the FIFO association.
    env.timing_monitor.inject_missing_commit_once = 1'b1;
    axi_write(5'h10, 32'h0303_0303, 4'b1111);
    env.axi_agent.driver.wait_for_limited_idle();

    env.timing_monitor.inject_orphan_snapshot_once = 1'b1;
    env.timing_monitor.inject_stale_snapshot_once  = 1'b1;
    axi_read(5'h00);
    env.axi_agent.driver.wait_for_limited_idle();

    env.timing_monitor.inject_duplicate_snapshot_once = 1'b1;
    axi_read(5'h00);
    env.axi_agent.driver.wait_for_limited_idle();

    // Keep missing snapshot last for the same FIFO-association reason as the
    // missing commit above.
    env.timing_monitor.inject_missing_snapshot_once = 1'b1;
    axi_read(5'h00);
    env.axi_agent.driver.wait_for_limited_idle();
    repeat (3) @(env.axi_agent.driver.vif.mon_cb);
    env.timing_monitor.audit_pending("controlled checker self-test drain");

    if ((env.timing_monitor.orphan_commit_count == 0) ||
        (env.timing_monitor.duplicate_commit_count == 0) ||
        (env.timing_monitor.missing_commit_count == 0) ||
        (env.timing_monitor.orphan_snapshot_count == 0) ||
        (env.timing_monitor.duplicate_snapshot_count == 0) ||
        (env.timing_monitor.missing_snapshot_count == 0) ||
        (env.timing_monitor.stale_epoch_count == 0) ||
        (env.timing_monitor.unqualified_b_count == 0) ||
        (env.timing_monitor.unqualified_r_count == 0))
      `uvm_error("C2_SELFTEST_MISSED",
        $sformatf("commit o/d/m=%0d/%0d/%0d snapshot o/d/m=%0d/%0d/%0d stale=%0d unqualified B/R=%0d/%0d",
                  env.timing_monitor.orphan_commit_count,
                  env.timing_monitor.duplicate_commit_count,
                  env.timing_monitor.missing_commit_count,
                  env.timing_monitor.orphan_snapshot_count,
                  env.timing_monitor.duplicate_snapshot_count,
                  env.timing_monitor.missing_snapshot_count,
                  env.timing_monitor.stale_epoch_count,
                  env.timing_monitor.unqualified_b_count,
                  env.timing_monitor.unqualified_r_count))
    else
      `uvm_info("C2_SELFTEST_PASS",
        $sformatf("expected faults detected without polluting normal regression: commit o/d/m=%0d/%0d/%0d snapshot o/d/m=%0d/%0d/%0d stale=%0d unqualified B/R=%0d/%0d",
                  env.timing_monitor.orphan_commit_count,
                  env.timing_monitor.duplicate_commit_count,
                  env.timing_monitor.missing_commit_count,
                  env.timing_monitor.orphan_snapshot_count,
                  env.timing_monitor.duplicate_snapshot_count,
                  env.timing_monitor.missing_snapshot_count,
                  env.timing_monitor.stale_epoch_count,
                  env.timing_monitor.unqualified_b_count,
                  env.timing_monitor.unqualified_r_count), UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
