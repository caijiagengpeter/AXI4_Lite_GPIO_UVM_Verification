`uvm_analysis_imp_decl(_stress_req)
`uvm_analysis_imp_decl(_stress_rsp)

class axi4l_v3_stress_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_v3_stress_test)

  uvm_analysis_imp_stress_req #(axi4l_seq_item, axi4l_v3_stress_test) req_imp;
  uvm_analysis_imp_stress_rsp #(axi4l_seq_item, axi4l_v3_stress_test) rsp_imp;
  axi4l_v3_stress_seq seq;
  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;
  int unsigned depth = 2;
  int max_write_depth, max_read_depth;
  int b_stalls, r_stalls, simultaneous_stalls, simultaneous_pending;
  int aw_stalls, w_stalls, ar_stalls, snapshot_hold_cycles;
  int write_credit_wait, read_credit_wait;
  int request_depth[int], response_depth[int];
  int snapshot_hits[int];
  bit credit_wait_seen[int];
  longint unsigned cycle;

  function new(string name = "axi4l_v3_stress_test", uvm_component parent = null);
    super.new(name, parent);
    req_imp = new("req_imp", this);
    rsp_imp = new("rsp_imp", this);
  endfunction

  function void build_phase(uvm_phase phase);
    void'($value$plusargs("V3_STRESS_DEPTH=%d", depth));
    if (!(depth inside {2,3}))
      `uvm_fatal("STRESS_DEPTH", "V3_STRESS_DEPTH must be 2 or 3")
    uvm_config_db#(bit)::set(this, "env.axi4l_agent.driver", "pipelined_mode", 1);
    uvm_config_db#(int unsigned)::set(this, "env.axi4l_agent.driver",
                                      "max_write_outstanding", depth);
    uvm_config_db#(int unsigned)::set(this, "env.axi4l_agent.driver",
                                      "max_read_outstanding", depth);
    super.build_phase(phase);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    env.axi_agent.monitor.request_ap.connect(req_imp);
    env.axi_agent.monitor.response_ap.connect(rsp_imp);
  endfunction

  function void write_stress_req(axi4l_seq_item tr);
    if (seq == null)
      `uvm_fatal("STRESS_NO_SEQ", "bus request without running sequence")
    seq.observe_request(tr);
  endfunction

  function void write_stress_rsp(axi4l_seq_item tr);
    seq.observe_response(tr);
  endfunction

  task sample_stats();
    axi4l_driver drv;
    axi4l_seq_item current_item;
    int w_reserved, r_reserved;
    drv = env.axi_agent.driver;
    forever begin
      @(vif.mon_cb);
      cycle++;
      // mon_cb contains pre-edge bus samples.  Wait one precision tick for
      // Driver and analysis callbacks to settle before checking bookkeeping.
      // Same-edge acceptance and retirement must count as one edge, not as a
      // spurious third outstanding item from callback execution order.
      #1ps;
      if (vif.mon_cb.ARESETN !== 1'b1 || seq == null)
        continue;
      if (vif.mon_cb.BVALID && !vif.mon_cb.BREADY) b_stalls++;
      if (vif.mon_cb.RVALID && !vif.mon_cb.RREADY) r_stalls++;
      if (vif.mon_cb.BVALID && !vif.mon_cb.BREADY &&
          vif.mon_cb.RVALID && !vif.mon_cb.RREADY) simultaneous_stalls++;
      if (vif.mon_cb.AWVALID && !vif.mon_cb.AWREADY) aw_stalls++;
      if (vif.mon_cb.WVALID && !vif.mon_cb.WREADY) w_stalls++;
      if (vif.mon_cb.ARVALID && !vif.mon_cb.ARREADY) ar_stalls++;

      if (drv.write_outstanding > max_write_depth)
        max_write_depth = drv.write_outstanding;
      if (drv.read_outstanding > max_read_depth)
        max_read_depth = drv.read_outstanding;
      if (drv.write_outstanding && drv.read_outstanding) simultaneous_pending++;
      if (drv.write_outstanding > depth || drv.read_outstanding > depth ||
          drv.write_credit_balance < 0 || drv.write_credit_balance > depth ||
          drv.read_credit_balance < 0 || drv.read_credit_balance > depth)
        `uvm_error("STRESS_CREDIT_RANGE", "outstanding/credit exceeds configured limit")

      // A credit also belongs to a partially driven request, before AW/W or
      // AR acceptance.  One dispatcher permits at most one such reservation.
      w_reserved = depth - drv.write_credit_balance - drv.write_outstanding;
      r_reserved = depth - drv.read_credit_balance - drv.read_outstanding;
      if (w_reserved < 0 || r_reserved < 0 || w_reserved+r_reserved > 1)
        `uvm_error("STRESS_CREDIT_ACCOUNTING", "credit ownership invariant failed")
      if (seq.write_pending.size() != drv.write_outstanding ||
          seq.read_pending.size() != drv.read_outstanding)
        `uvm_error("STRESS_BUS_DEPTH", "Driver depth differs from observed bus FIFO")

      current_item = env.axi_agent.sequencer.get_current_item();
      if (current_item != null) begin
        if (current_item.access == AXI4L_WRITE &&
            drv.write_credit_balance == 0 && drv.write_outstanding == depth)
          write_credit_wait++;
        if (current_item.access == AXI4L_READ &&
            drv.read_credit_balance == 0 && drv.read_outstanding == depth)
          read_credit_wait++;
        if (((current_item.access == AXI4L_WRITE &&
              drv.write_credit_balance == 0 && drv.write_outstanding == depth) ||
             (current_item.access == AXI4L_READ &&
              drv.read_credit_balance == 0 && drv.read_outstanding == depth)) &&
            !credit_wait_seen.exists(current_item.get_transaction_id())) begin
          credit_wait_seen[current_item.get_transaction_id()] = 1;
          `uvm_info("STRESS_CREDIT_WAIT",
            $sformatf("%s seq_id=%0d tr_id=%0d wait_cycle=%0d outstanding=%0d tokens=0",
              current_item.access.name(), current_item.get_sequence_id(),
              current_item.get_transaction_id(), cycle, depth), UVM_NONE)
        end
      end
      foreach (seq.requests[i]) begin
        if (seq.bus_requests[i] != null && seq.bus_requests[i].accept_cycle == cycle)
          request_depth[i] = (seq.requests[i].access == AXI4L_WRITE)
                          ? drv.write_outstanding : drv.read_outstanding;
        if (seq.bus_responses[i] != null && seq.bus_responses[i].response_cycle == cycle)
          response_depth[i] = (seq.requests[i].access == AXI4L_WRITE)
                           ? drv.write_outstanding : drv.read_outstanding;
      end
      if (seq.read_pending.size() != 0 && vif.mon_cb.RVALID && !vif.mon_cb.RREADY) begin
        int index;
        index = seq.read_pending[0];
        if (seq.stages[index] == "mixed" && seq.requests[index].addr == 0 &&
            vif.mon_cb.RDATA === seq.read_expected[index] &&
            vif.mon_cb.RDATA != env.gpio_agent_h.monitor.vif.mon_cb.o_gpio) begin
          snapshot_hold_cycles++;
          snapshot_hits[index]++;
          if (snapshot_hits[index] == 1)
            `uvm_info("STRESS_SNAPSHOT",
              $sformatf("tr_id=%0d AR_cycle=%0d hold_cycle=%0d RDATA=%08h changed_GPIO=%08h",
                seq.requests[index].get_transaction_id(),
                seq.bus_requests[index].accept_cycle, cycle, vif.mon_cb.RDATA,
                env.gpio_agent_h.monitor.vif.mon_cb.o_gpio), UVM_NONE)
        end
      end
    end
  endtask

  task probe_credits(semaphore credits, string channel_name);
    // SV semaphores have no get_num().  An atomic idle-only probe verifies
    // actual tokens, independently of the Driver's diagnostic balance.
    if (!credits.try_get(depth))
      `uvm_error("STRESS_CREDIT_LEAK", {channel_name, " tokens missing at drain"})
    else begin
      if (credits.try_get(1)) begin
        `uvm_error("STRESS_DOUBLE_RELEASE", {channel_name, " has excess token"})
        credits.put(1);
      end
      credits.put(depth);
    end
  endtask

  task run_phase(uvm_phase phase);
    bit finished;
    phase.raise_objection(this);
    vif = env.axi_agent.driver.vif;
    seq = axi4l_v3_stress_seq::type_id::create("seq");
    seq.vif = vif;
    fork : run_guard
      sample_stats();
      begin
        do @(vif.mon_cb); while (vif.mon_cb.ARESETN !== 1'b1);
        seq.start(env.axi_agent.sequencer);
        env.axi_agent.driver.wait_for_pipelined_idle();
        repeat (3) @(vif.mon_cb);
        #2ps;
        finished = 1;
      end
      begin
        repeat (7000) @(vif.mon_cb);
        `uvm_fatal("STRESS_TIMEOUT", "stress request or response did not finish")
      end
    join_any
    disable run_guard;
    if (!finished)
      `uvm_fatal("STRESS_INCOMPLETE", "stress ended before all responses")
    seq.audit();
    foreach (seq.requests[i]) begin
      if (!request_depth.exists(i) || !response_depth.exists(i))
        `uvm_error("STRESS_MISSING_DEPTH", "per-request depth sampling missing")
      if (seq.stages[i] == "mixed" && seq.requests[i].access == AXI4L_READ &&
          seq.requests[i].addr == 0 && !snapshot_hits.exists(i))
        `uvm_error("STRESS_MISSING_SNAPSHOT", "mixed read did not hold old data across GPIO change")
      if (seq.responses[i] != null && seq.bus_requests[i] != null)
        `uvm_info("STRESS_TIMING",
          $sformatf("stage=%s %s seq_id=%0d tr_id=%0d AW=%0d W=%0d request=%0d response=%0d depth_at_request=%0d depth_after_response=%0d rdata=%08h",
            seq.stages[i], seq.requests[i].access.name(),
            seq.requests[i].get_sequence_id(), seq.requests[i].get_transaction_id(),
            seq.bus_requests[i].aw_cycle, seq.bus_requests[i].w_cycle,
            seq.bus_requests[i].accept_cycle, seq.responses[i].response_cycle,
            request_depth[i], response_depth[i], seq.responses[i].rdata), UVM_NONE)
    end
    if (max_write_depth < 2 || max_read_depth < 2 ||
        b_stalls == 0 || r_stalls == 0 || simultaneous_stalls == 0 ||
        simultaneous_pending == 0 || snapshot_hold_cycles == 0)
      `uvm_error("STRESS_COVERAGE", "required overlap/stall/snapshot evidence missing")
    if (depth == 2 && (write_credit_wait == 0 || read_credit_wait == 0))
      `uvm_error("STRESS_NO_CREDIT_WAIT", "depth two did not exhaust both credits")
    if (env.axi_agent.driver.pending_write_response_fifo.num() ||
        env.axi_agent.driver.pending_read_response_fifo.num() ||
        env.axi_agent.driver.write_outstanding || env.axi_agent.driver.read_outstanding ||
        env.axi_agent.driver.write_credit_balance != depth ||
        env.axi_agent.driver.read_credit_balance != depth)
      `uvm_error("STRESS_NOT_DRAINED", "pending context or credit balance not drained")
    probe_credits(env.axi_agent.driver.write_credits, "WRITE");
    probe_credits(env.axi_agent.driver.read_credits, "READ");
    `uvm_info("STRESS_SUMMARY",
      $sformatf("configured=%0d observed_W=%0d observed_R=%0d B_stall=%0d R_stall=%0d simultaneous_stall=%0d simultaneous_pending=%0d AW_stall=%0d W_stall=%0d AR_stall=%0d W_credit_wait=%0d R_credit_wait=%0d snapshot_hold=%0d final_credit_W=%0d final_credit_R=%0d",
        depth, max_write_depth, max_read_depth, b_stalls, r_stalls,
        simultaneous_stalls, simultaneous_pending, aw_stalls, w_stalls, ar_stalls,
        write_credit_wait, read_credit_wait, snapshot_hold_cycles,
        env.axi_agent.driver.write_credit_balance,
        env.axi_agent.driver.read_credit_balance), UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
