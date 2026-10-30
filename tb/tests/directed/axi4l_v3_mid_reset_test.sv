class axi4l_v3_mid_reset_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_v3_mid_reset_test)

  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;

  function new(string name = "axi4l_v3_mid_reset_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    uvm_config_db#(bit)::set(this, "env.axi4l_agent.driver",
                             "pipelined_mode", 1'b1);
    uvm_config_db#(int unsigned)::set(this, "env.axi4l_agent.driver",
                                      "max_write_outstanding", 2);
    uvm_config_db#(int unsigned)::set(this, "env.axi4l_agent.driver",
                                      "max_read_outstanding", 2);
    super.build_phase(phase);
  endfunction

  task automatic pulse_reset(string scenario_name);
    `uvm_info("V3_RESET_INJECT",
      $sformatf("scenario=%s cycle=%0d state AW=%0b/%0b W=%0b/%0b B=%0b/%0b AR=%0b/%0b R=%0b/%0b write_outstanding=%0d read_outstanding=%0d",
                scenario_name, env.axi_agent.driver.driver_cycle,
                vif.mon_cb.AWVALID, vif.mon_cb.AWREADY,
                vif.mon_cb.WVALID,  vif.mon_cb.WREADY,
                vif.mon_cb.BVALID,  vif.mon_cb.BREADY,
                vif.mon_cb.ARVALID, vif.mon_cb.ARREADY,
                vif.mon_cb.RVALID,  vif.mon_cb.RREADY,
                env.axi_agent.driver.write_outstanding,
                env.axi_agent.driver.read_outstanding), UVM_NONE)

    vif.ARESETN <= 1'b0;
    repeat (2) @(vif.mon_cb);
    if (vif.mon_cb.ARESETN !== 1'b0)
      `uvm_error("V3_RESET_NOT_ASSERTED",
                 $sformatf("%s reset was not sampled low", scenario_name))
    if (vif.mon_cb.AWVALID || vif.mon_cb.WVALID || vif.mon_cb.ARVALID ||
        vif.mon_cb.BREADY || vif.mon_cb.RREADY)
      `uvm_error("V3_RESET_PINS_NOT_IDLE",
        $sformatf("%s master outputs not withdrawn during reset: AWVALID=%0b WVALID=%0b ARVALID=%0b BREADY=%0b RREADY=%0b",
                  scenario_name, vif.mon_cb.AWVALID, vif.mon_cb.WVALID,
                  vif.mon_cb.ARVALID, vif.mon_cb.BREADY, vif.mon_cb.RREADY))
    @(vif.mon_cb);
    vif.ARESETN <= 1'b1;
    do @(vif.mon_cb); while (vif.mon_cb.ARESETN !== 1'b1);
    `uvm_info("V3_RESET_RELEASE",
      $sformatf("scenario=%s cycle=%0d", scenario_name,
                env.axi_agent.driver.driver_cycle), UVM_NONE)
  endtask

  task automatic inject_partial_write_reset();
    forever begin
      @(vif.mon_cb);
      if ((vif.mon_cb.ARESETN === 1'b1) &&
          vif.mon_cb.AWVALID && vif.mon_cb.AWREADY) begin
        if (vif.mon_cb.WVALID)
          `uvm_error("V3_RESET_PARTIAL_STATE",
                     "partial-write injection expected WVALID still low")
        pulse_reset("partial_write_aw_complete_w_not_issued");
        return;
      end
    end
  endtask

  task automatic inject_pending_b_reset();
    forever begin
      @(vif.mon_cb);
      if ((vif.mon_cb.ARESETN === 1'b1) &&
          vif.mon_cb.BVALID && !vif.mon_cb.BREADY) begin
        pulse_reset("pending_b_blocked_by_bready");
        return;
      end
    end
  endtask

  task automatic inject_pending_r_reset();
    forever begin
      @(vif.mon_cb);
      if ((vif.mon_cb.ARESETN === 1'b1) &&
          vif.mon_cb.RVALID && !vif.mon_cb.RREADY) begin
        pulse_reset("pending_r_blocked_by_rready");
        return;
      end
    end
  endtask

  task automatic inject_multi_rw_reset();
    forever begin
      @(vif.mon_cb);
      if ((vif.mon_cb.ARESETN === 1'b1) &&
          (env.axi_agent.driver.write_outstanding >= 2) &&
          (env.axi_agent.driver.read_outstanding >= 2) &&
          vif.mon_cb.BVALID && !vif.mon_cb.BREADY &&
          vif.mon_cb.RVALID && !vif.mon_cb.RREADY) begin
        pulse_reset("two_write_two_read_outstanding");
        return;
      end
    end
  endtask

  task automatic inject_credit_wait_reset();
    forever begin
      @(vif.mon_cb);
      if ((vif.mon_cb.ARESETN === 1'b1) &&
          (env.axi_agent.driver.write_outstanding == 2) &&
          (env.axi_agent.driver.write_credit_balance == 0) &&
          (env.axi_agent.sequencer.get_current_item() != null) &&
          vif.mon_cb.BVALID && !vif.mon_cb.BREADY) begin
        pulse_reset("request_fetched_waiting_for_write_credit");
        return;
      end
    end
  endtask

  task automatic inject_after_completed_boundary();
    bit saw_b_handshake;
    bit saw_r_handshake;
    while (!(saw_b_handshake && saw_r_handshake)) begin
      @(vif.mon_cb);
      if ((vif.mon_cb.ARESETN === 1'b1) &&
          vif.mon_cb.BVALID && vif.mon_cb.BREADY)
        saw_b_handshake = 1'b1;
      if ((vif.mon_cb.ARESETN === 1'b1) &&
          vif.mon_cb.RVALID && vif.mon_cb.RREADY)
        saw_r_handshake = 1'b1;
    end
    pulse_reset("after_completed_b_and_r_handshakes");
  endtask

  task automatic run_reset_scenario(axi4l_v3_mid_reset_seq seq);
    bit completed;
    completed = 1'b0;
    fork : guarded_scenario
      begin
        fork
          seq.start(env.axi_agent.sequencer);
          begin
            case (seq.scenario)
              V3_MID_RESET_PARTIAL_WRITE:      inject_partial_write_reset();
              V3_MID_RESET_PENDING_B:          inject_pending_b_reset();
              V3_MID_RESET_PENDING_R:          inject_pending_r_reset();
              V3_MID_RESET_MULTI_RW:           inject_multi_rw_reset();
              V3_MID_RESET_CREDIT_WAIT:        inject_credit_wait_reset();
              V3_MID_RESET_COMPLETED_BOUNDARY: inject_after_completed_boundary();
              default:
                `uvm_fatal("V3_RESET_TEST_SCENARIO",
                           "run_reset_scenario received non-reset sequence")
            endcase
          end
        join
        completed = 1'b1;
      end
      begin
        repeat (600) @(vif.mon_cb);
        if (!completed)
          `uvm_fatal("V3_RESET_TIMEOUT",
            $sformatf("scenario %s did not complete", seq.scenario_name()))
      end
    join_any
    disable guarded_scenario;
  endtask

  task automatic check_driver_drained(string scenario_name);
    env.axi_agent.driver.wait_for_pipelined_idle();
    repeat (2) @(vif.mon_cb);
    if ((env.axi_agent.driver.write_outstanding != 0) ||
        (env.axi_agent.driver.read_outstanding != 0) ||
        (env.axi_agent.driver.pending_write_response_fifo.num() != 0) ||
        (env.axi_agent.driver.pending_read_response_fifo.num() != 0))
      `uvm_error("V3_RESET_NOT_DRAINED",
        $sformatf("%s write_outstanding=%0d read_outstanding=%0d write_fifo=%0d read_fifo=%0d",
                  scenario_name,
                  env.axi_agent.driver.write_outstanding,
                  env.axi_agent.driver.read_outstanding,
                  env.axi_agent.driver.pending_write_response_fifo.num(),
                  env.axi_agent.driver.pending_read_response_fifo.num()))
    if ((env.axi_agent.driver.write_credit_balance != 2) ||
        (env.axi_agent.driver.read_credit_balance != 2))
      `uvm_error("V3_RESET_CREDIT_LEAK",
        $sformatf("%s write_credits=%0d/2 read_credits=%0d/2",
                  scenario_name,
                  env.axi_agent.driver.write_credit_balance,
                  env.axi_agent.driver.read_credit_balance))
    `uvm_info("V3_RESET_DRAINED",
      $sformatf("scenario=%s write_fifo=0 read_fifo=0 write_credits=%0d read_credits=%0d",
                scenario_name,
                env.axi_agent.driver.write_credit_balance,
                env.axi_agent.driver.read_credit_balance), UVM_NONE)
  endtask

  task automatic run_recovery(int unsigned index);
    axi4l_v3_mid_reset_seq seq;
    bit completed;
    seq = axi4l_v3_mid_reset_seq::type_id::create(
      $sformatf("recovery_seq_%0d", index));
    seq.vif                 = vif;
    seq.scenario            = V3_MID_RESET_RECOVERY;
    seq.base_transaction_id = 1000 + (index * 10);
    // Keep recovery data inside the implemented GPIO output width so the
    // readback compares architectural bits rather than reserved upper bits.
    seq.recovery_data       = 32'h200d_0000 | index;
    completed = 1'b0;
    fork : guarded_recovery
      begin
        seq.start(env.axi_agent.sequencer);
        completed = 1'b1;
      end
      begin
        repeat (300) @(vif.mon_cb);
        if (!completed)
          `uvm_fatal("V3_RESET_RECOVERY_TIMEOUT",
                     $sformatf("recovery %0d did not complete", index))
      end
    join_any
    disable guarded_recovery;
    check_driver_drained($sformatf("recovery_%0d", index));
    `uvm_info("V3_RESET_RECOVERY_PASS",
      $sformatf("recovery=%0d write/read data=0x%08h",
                index, seq.recovery_data), UVM_NONE)
  endtask

  task automatic execute_scenario(axi4l_v3_mid_reset_scenario_e scenario,
                                  int unsigned index);
    axi4l_v3_mid_reset_seq seq;
    seq = axi4l_v3_mid_reset_seq::type_id::create(
      $sformatf("mid_reset_seq_%0d", index));
    seq.vif                 = vif;
    seq.scenario            = scenario;
    seq.base_transaction_id = 100 + (index * 10);
    seq.recovery_data       = 32'h2ace_0000 | index;
    run_reset_scenario(seq);
    check_driver_drained(seq.scenario_name());
    run_recovery(index);
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    vif = env.axi_agent.driver.vif;
    do @(vif.mon_cb); while (vif.mon_cb.ARESETN !== 1'b1);
    repeat (2) @(vif.mon_cb);

    execute_scenario(V3_MID_RESET_PARTIAL_WRITE,      1);
    execute_scenario(V3_MID_RESET_PENDING_B,          2);
    execute_scenario(V3_MID_RESET_PENDING_R,          3);
    execute_scenario(V3_MID_RESET_MULTI_RW,           4);
    execute_scenario(V3_MID_RESET_CREDIT_WAIT,        5);
    execute_scenario(V3_MID_RESET_COMPLETED_BOUNDARY, 6);

    `uvm_info("V3_MID_RESET_PASS",
      "all six reset scenarios and post-reset recoveries completed", UVM_NONE)
    repeat (3) @(vif.mon_cb);
    phase.drop_objection(this);
  endtask
endclass
