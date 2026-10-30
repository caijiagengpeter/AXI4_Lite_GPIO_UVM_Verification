class axi4l_c2_timing_monitor extends uvm_monitor;
  `uvm_component_utils(axi4l_c2_timing_monitor)

  typedef struct packed {
    bit [AXI4L_ADDR_WIDTH-1:0] addr;
    bit [2:0]                  prot;
    longint unsigned           cycle;
  } aw_sample_t;

  typedef struct packed {
    bit [AXI4L_DATA_WIDTH-1:0]   data;
    bit [AXI4L_DATA_WIDTH/8-1:0] strb;
    longint unsigned             cycle;
  } w_sample_t;

  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;
  virtual axi4l_c2_timing_if timing_vif;
  uvm_analysis_port #(axi4l_c2_event) event_ap;

  aw_sample_t aw_q[$];
  w_sample_t  w_q[$];
  axi4l_seq_item accepted_write_q[$];
  axi4l_seq_item accepted_read_q[$];
  longint unsigned accepted_write_epoch_q[$];
  longint unsigned accepted_read_epoch_q[$];
  axi4l_seq_item committed_write_q[$];
  axi4l_seq_item snapshotted_read_q[$];
  longint unsigned committed_write_epoch_q[$];
  longint unsigned snapshotted_read_epoch_q[$];

  bit whitebox_enable = 1'b1;
  bit selftest_mode;
  bit reset_seen = 1'b1;
  longint unsigned cycle_count;
  longint unsigned current_epoch;
  longint unsigned next_write_id;
  longint unsigned next_read_id;

  longint unsigned accepted_write_count;
  longint unsigned accepted_read_count;
  longint unsigned write_commit_count;
  longint unsigned read_snapshot_count;
  longint unsigned write_response_count;
  longint unsigned read_response_count;
  longint unsigned b_stall_cycles;
  longint unsigned r_stall_cycles;
  longint unsigned same_edge_rw_count;
  longint unsigned buffered_nonzero_side_effect_count;
  longint unsigned delayed_snapshot_count;
  longint unsigned reset_count;
  longint unsigned last_write_accept_cycle;
  longint unsigned last_write_commit_cycle;
  longint unsigned last_read_accept_cycle;
  longint unsigned last_read_snapshot_cycle;
  longint unsigned evidence_buffer_accept_cycle;
  longint unsigned evidence_buffer_commit_cycle;
  longint unsigned evidence_delayed_ar_cycle;
  longint unsigned evidence_delayed_snapshot_cycle;
  longint unsigned evidence_same_edge_cycle;

  int unsigned violation_count;
  int unsigned orphan_commit_count;
  int unsigned duplicate_commit_count;
  int unsigned missing_commit_count;
  int unsigned orphan_snapshot_count;
  int unsigned duplicate_snapshot_count;
  int unsigned missing_snapshot_count;
  int unsigned stale_epoch_count;
  int unsigned unqualified_b_count;
  int unsigned unqualified_r_count;

  // Test-only one-shot checker fault injection.  These bits alter only the
  // monitor/checker event stream; they never force or modify DUT signals.
  bit inject_orphan_commit_once;
  bit inject_duplicate_commit_once;
  bit inject_missing_commit_once;
  bit inject_stale_commit_once;

  bit commit_seen[string];
  bit snapshot_seen[string];

  function new(string name = "axi4l_c2_timing_monitor",
               uvm_component parent = null);
    super.new(name, parent);
    event_ap = new("event_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4l_if #(AXI4L_ADDR_WIDTH,
                                           AXI4L_DATA_WIDTH))::get(
          this, "", "vif", vif))
      `uvm_fatal("C2_NOVIF", "C2 timing monitor did not receive AXI vif")
    void'(uvm_config_db#(bit)::get(this, "", "c2_whitebox_enable",
                                   whitebox_enable));
    void'(uvm_config_db#(bit)::get(this, "", "c2_selftest_mode",
                                   selftest_mode));
    if (whitebox_enable &&
        !uvm_config_db#(virtual axi4l_c2_timing_if)::get(
          this, "", "timing_vif", timing_vif)) begin
      whitebox_enable = 1'b0;
      `uvm_warning("C2_BLACKBOX",
        "timing_vif unavailable: using acceptance-time fallback; cycle-exact commit/snapshot checking is disabled")
    end
  endfunction

  function void clear_epoch_queues();
    aw_q.delete();
    w_q.delete();
    accepted_write_q.delete();
    accepted_read_q.delete();
    accepted_write_epoch_q.delete();
    accepted_read_epoch_q.delete();
    committed_write_q.delete();
    snapshotted_read_q.delete();
    committed_write_epoch_q.delete();
    snapshotted_read_epoch_q.delete();
  endfunction

  function void violation(string id, string message);
    violation_count++;
    if (selftest_mode)
      `uvm_info("C2_EXPECTED_FAULT", {id, ": ", message}, UVM_NONE)
    else
      `uvm_error(id, message)
  endfunction

  function automatic string request_key(longint unsigned epoch,
                                        longint unsigned request_id);
    return $sformatf("%0d:%0d", epoch, request_id);
  endfunction

  function automatic axi4l_seq_item clone_request(axi4l_seq_item source,
                                                   string name);
    axi4l_seq_item copy;
    if (!$cast(copy, source.clone()))
      `uvm_fatal("C2_CLONE", {"failed to clone ", name})
    return copy;
  endfunction

  function void publish_event(axi4l_c2_event_kind_e kind,
                              axi4l_seq_item request,
                              longint unsigned epoch,
                              longint unsigned event_cycle);
    axi4l_c2_event event_item;
    event_item = axi4l_c2_event::type_id::create("c2_event");
    event_item.kind           = kind;
    event_item.request        = clone_request(request, "timing request");
    event_item.epoch          = epoch;
    event_item.event_cycle    = event_cycle;
    event_item.whitebox_exact = whitebox_enable;
    event_ap.write(event_item);
  endfunction

  function void handle_write_commit(longint unsigned event_cycle);
    axi4l_seq_item request;
    longint unsigned request_epoch;
    string key;

    if (inject_orphan_commit_once) begin
      inject_orphan_commit_once = 1'b0;
      orphan_commit_count++;
      violation("C2_ORPHAN_COMMIT",
        $sformatf("injected commit at cycle %0d has no accepted AW/W request",
                  event_cycle));
    end

    if (accepted_write_q.size() == 0) begin
      orphan_commit_count++;
      violation("C2_ORPHAN_COMMIT",
        $sformatf("WRITE_COMMIT at cycle %0d has no pending accepted AW/W pair",
                  event_cycle));
      return;
    end

    if (inject_missing_commit_once) begin
      inject_missing_commit_once = 1'b0;
      `uvm_info("C2_FAULT_INJECT",
        $sformatf("suppressed WRITE_COMMIT at cycle %0d for missing-event self-test",
                  event_cycle), UVM_NONE)
      return;
    end

    request       = accepted_write_q.pop_front();
    request_epoch = accepted_write_epoch_q.pop_front();
    if (inject_stale_commit_once) begin
      inject_stale_commit_once = 1'b0;
      stale_epoch_count++;
      violation("C2_STALE_EPOCH",
        $sformatf("injected stale commit request epoch=%0d current=%0d cycle=%0d",
                  request_epoch, current_epoch + 1, event_cycle));
    end
    if (request_epoch != current_epoch) begin
      stale_epoch_count++;
      violation("C2_STALE_EPOCH",
        $sformatf("commit request epoch=%0d current=%0d cycle=%0d",
                  request_epoch, current_epoch, event_cycle));
      return;
    end

    key = request_key(request_epoch, request.transaction_id);
    if (commit_seen.exists(key)) begin
      duplicate_commit_count++;
      violation("C2_DUPLICATE_COMMIT",
        $sformatf("duplicate commit epoch=%0d request=%0d cycle=%0d",
                  request_epoch, request.transaction_id, event_cycle));
      return;
    end
    commit_seen[key] = 1'b1;
    write_commit_count++;
    last_write_commit_cycle = event_cycle;
    committed_write_q.push_back(clone_request(request, "committed write"));
    committed_write_epoch_q.push_back(request_epoch);
    publish_event(AXI4L_C2_WRITE_COMMIT, request, request_epoch, event_cycle);
    if ((request.accept_cycle < event_cycle) && (request.strb != '0) &&
        (request.addr[AXI4L_ADDR_WIDTH-1:2] inside {3'd1, 3'd2, 3'd3})) begin
      buffered_nonzero_side_effect_count++;
      if (evidence_buffer_commit_cycle == 0) begin
        evidence_buffer_accept_cycle = request.accept_cycle;
        evidence_buffer_commit_cycle = event_cycle;
      end
    end
    `uvm_info("C2_WRITE_COMMIT",
      $sformatf("epoch=%0d request=%0d AW=%0d W=%0d commit=%0d addr=0x%02h data=0x%08h strb=0x%0h prot=%0h mode=%s",
                request_epoch, request.transaction_id, request.aw_cycle,
                request.w_cycle, event_cycle, request.addr, request.data,
                request.strb, request.prot,
                whitebox_enable ? "white-box" : "black-box"), UVM_MEDIUM)

    if (inject_duplicate_commit_once) begin
      inject_duplicate_commit_once = 1'b0;
      duplicate_commit_count++;
      violation("C2_DUPLICATE_COMMIT",
        $sformatf("injected duplicate commit epoch=%0d request=%0d cycle=%0d",
                  request_epoch, request.transaction_id, event_cycle));
    end
  endfunction

  function void handle_read_snapshot(longint unsigned event_cycle);
    axi4l_seq_item request;
    longint unsigned request_epoch;
    string key;
    if (accepted_read_q.size() == 0) begin
      orphan_snapshot_count++;
      violation("C2_ORPHAN_SNAPSHOT",
        $sformatf("READ_SNAPSHOT at cycle %0d has no pending accepted AR",
                  event_cycle));
      return;
    end
    request       = accepted_read_q.pop_front();
    request_epoch = accepted_read_epoch_q.pop_front();
    if (request_epoch != current_epoch) begin
      stale_epoch_count++;
      violation("C2_STALE_EPOCH",
        $sformatf("snapshot request epoch=%0d current=%0d cycle=%0d",
                  request_epoch, current_epoch, event_cycle));
      return;
    end
    key = request_key(request_epoch, request.transaction_id);
    if (snapshot_seen.exists(key)) begin
      duplicate_snapshot_count++;
      violation("C2_DUPLICATE_SNAPSHOT",
        $sformatf("duplicate snapshot epoch=%0d request=%0d cycle=%0d",
                  request_epoch, request.transaction_id, event_cycle));
      return;
    end
    snapshot_seen[key] = 1'b1;
    read_snapshot_count++;
    last_read_snapshot_cycle = event_cycle;
    snapshotted_read_q.push_back(clone_request(request, "snapshotted read"));
    snapshotted_read_epoch_q.push_back(request_epoch);
    publish_event(AXI4L_C2_READ_SNAPSHOT, request, request_epoch, event_cycle);
    if (request.accept_cycle < event_cycle) begin
      delayed_snapshot_count++;
      if (evidence_delayed_snapshot_cycle == 0) begin
        evidence_delayed_ar_cycle       = request.accept_cycle;
        evidence_delayed_snapshot_cycle = event_cycle;
      end
    end
    `uvm_info("C2_READ_SNAPSHOT",
      $sformatf("epoch=%0d request=%0d AR=%0d snapshot=%0d addr=0x%02h prot=%0h mode=%s",
                request_epoch, request.transaction_id, request.accept_cycle,
                event_cycle, request.addr, request.prot,
                whitebox_enable ? "white-box" : "black-box"), UVM_MEDIUM)
  endfunction

  function void audit_pending(string reason = "end-of-test");
    while (accepted_write_q.size() != 0) begin
      missing_commit_count++;
      violation("C2_MISSING_COMMIT",
        $sformatf("%s: accepted write request=%0d epoch=%0d AW=%0d W=%0d never committed",
                  reason, accepted_write_q[0].transaction_id,
                  accepted_write_epoch_q[0], accepted_write_q[0].aw_cycle,
                  accepted_write_q[0].w_cycle));
      void'(accepted_write_q.pop_front());
      void'(accepted_write_epoch_q.pop_front());
    end
    while (accepted_read_q.size() != 0) begin
      missing_snapshot_count++;
      violation("C2_MISSING_SNAPSHOT",
        $sformatf("%s: accepted read request=%0d epoch=%0d AR=%0d never snapshotted",
                  reason, accepted_read_q[0].transaction_id,
                  accepted_read_epoch_q[0],
                  accepted_read_q[0].accept_cycle));
      void'(accepted_read_q.pop_front());
      void'(accepted_read_epoch_q.pop_front());
    end
    while (committed_write_q.size() != 0) begin
      violation("C2_MISSING_B",
        $sformatf("%s: committed write request=%0d has no B handshake",
                  reason, committed_write_q[0].transaction_id));
      void'(committed_write_q.pop_front());
      void'(committed_write_epoch_q.pop_front());
    end
    while (snapshotted_read_q.size() != 0) begin
      violation("C2_MISSING_R",
        $sformatf("%s: snapshotted read request=%0d has no R handshake",
                  reason, snapshotted_read_q[0].transaction_id));
      void'(snapshotted_read_q.pop_front());
      void'(snapshotted_read_epoch_q.pop_front());
    end
  endfunction

  task run_phase(uvm_phase phase);
    aw_sample_t aw;
    w_sample_t  w;
    axi4l_seq_item request;
    bit write_event;
    bit read_event;
    bit blackbox_write_event;
    bit blackbox_read_event;

    clear_epoch_queues();
    forever begin
      @(vif.mon_cb);
      cycle_count++;
      write_event = 1'b0;
      read_event  = 1'b0;
      blackbox_write_event = 1'b0;
      blackbox_read_event  = 1'b0;

      if (vif.mon_cb.ARESETN !== 1'b1) begin
        if (!reset_seen) begin
          reset_seen = 1'b1;
          current_epoch++;
          reset_count++;
          clear_epoch_queues();
          `uvm_info("C2_RESET",
            $sformatf("entered reset at cycle=%0d new_epoch=%0d; pending accepted/executed queues discarded",
                      cycle_count, current_epoch), UVM_MEDIUM)
        end
        continue;
      end
      if (reset_seen) begin
        reset_seen = 1'b0;
        `uvm_info("C2_RESET",
          $sformatf("left reset at cycle=%0d epoch=%0d", cycle_count,
                    current_epoch), UVM_MEDIUM)
      end

      if (vif.mon_cb.BVALID && !vif.mon_cb.BREADY) b_stall_cycles++;
      if (vif.mon_cb.RVALID && !vif.mon_cb.RREADY) r_stall_cycles++;

      if (vif.mon_cb.AWVALID && vif.mon_cb.AWREADY) begin
        aw.addr  = vif.mon_cb.AWADDR;
        aw.prot  = vif.mon_cb.AWPROT;
        aw.cycle = cycle_count;
        aw_q.push_back(aw);
      end
      if (vif.mon_cb.WVALID && vif.mon_cb.WREADY) begin
        w.data   = vif.mon_cb.WDATA;
        w.strb   = vif.mon_cb.WSTRB;
        w.cycle  = cycle_count;
        w_q.push_back(w);
      end
      while ((aw_q.size() != 0) && (w_q.size() != 0)) begin
        aw = aw_q.pop_front();
        w  = w_q.pop_front();
        request = axi4l_seq_item::type_id::create("c2_accepted_write");
        request.access         = AXI4L_WRITE;
        request.addr           = aw.addr;
        request.prot           = aw.prot;
        request.data           = w.data;
        request.strb           = w.strb;
        request.transaction_id = next_write_id++;
        request.aw_cycle       = aw.cycle;
        request.w_cycle        = w.cycle;
        request.accept_cycle   = (aw.cycle > w.cycle) ? aw.cycle : w.cycle;
        accepted_write_q.push_back(request);
        accepted_write_epoch_q.push_back(current_epoch);
        accepted_write_count++;
        last_write_accept_cycle = request.accept_cycle;
        blackbox_write_event = 1'b1;
      end

      if (vif.mon_cb.ARVALID && vif.mon_cb.ARREADY) begin
        request = axi4l_seq_item::type_id::create("c2_accepted_read");
        request.access         = AXI4L_READ;
        request.addr           = vif.mon_cb.ARADDR;
        request.prot           = vif.mon_cb.ARPROT;
        request.transaction_id = next_read_id++;
        request.accept_cycle   = cycle_count;
        accepted_read_q.push_back(request);
        accepted_read_epoch_q.push_back(current_epoch);
        accepted_read_count++;
        last_read_accept_cycle = cycle_count;
        blackbox_read_event = 1'b1;
      end

      // A response visible before this edge can only belong to an execution
      // event from an earlier edge.  Retire response eligibility first, then
      // process a same-edge replacement commit/snapshot below.
      if (vif.mon_cb.BVALID && vif.mon_cb.BREADY) begin
        if (committed_write_q.size() == 0) begin
          unqualified_b_count++;
          violation("C2_B_UNQUALIFIED",
            $sformatf("B handshake at cycle %0d has no committed write",
                      cycle_count));
        end else begin
          void'(committed_write_q.pop_front());
          void'(committed_write_epoch_q.pop_front());
          write_response_count++;
        end
      end
      if (vif.mon_cb.RVALID && vif.mon_cb.RREADY) begin
        if (snapshotted_read_q.size() == 0) begin
          unqualified_r_count++;
          violation("C2_R_UNQUALIFIED",
            $sformatf("R handshake at cycle %0d has no snapshotted read",
                      cycle_count));
        end else begin
          void'(snapshotted_read_q.pop_front());
          void'(snapshotted_read_epoch_q.pop_front());
          read_response_count++;
        end
      end

      if (whitebox_enable) begin
        if (timing_vif.mon_cb.WRITE_COMMIT === 1'b1) begin
          handle_write_commit(cycle_count);
          write_event = 1'b1;
        end
        if (timing_vif.mon_cb.READ_SNAPSHOT === 1'b1) begin
          handle_read_snapshot(cycle_count);
          read_event = 1'b1;
        end
      end else begin
        if (blackbox_write_event) begin
          handle_write_commit(cycle_count);
          write_event = 1'b1;
        end
        if (blackbox_read_event) begin
          handle_read_snapshot(cycle_count);
          read_event = 1'b1;
        end
      end
      if (write_event && read_event) begin
        same_edge_rw_count++;
        if (evidence_same_edge_cycle == 0)
          evidence_same_edge_cycle = cycle_count;
        `uvm_info("C2_SAME_EDGE_RW",
          $sformatf("cycle=%0d read snapshot uses pre-NBA state; write becomes visible after NBA",
                    cycle_count), UVM_MEDIUM)
      end
    end
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    audit_pending("end-of-test controlled drain");
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (!selftest_mode && (violation_count != 0))
      `uvm_error("C2_TIMING_FAIL",
        $sformatf("violations=%0d accepted W/R=%0d/%0d commit/snapshot=%0d/%0d B/R=%0d/%0d",
                  violation_count, accepted_write_count, accepted_read_count,
                  write_commit_count, read_snapshot_count,
                  write_response_count, read_response_count))
    else
      `uvm_info("C2_TIMING_SUMMARY",
        $sformatf("mode=%s epoch=%0d accepted W/R=%0d/%0d commit/snapshot=%0d/%0d B/R=%0d/%0d Bstall/Rstall=%0d/%0d buffered_side_effect=%0d delayed_snapshot=%0d same-edge=%0d resets=%0d violations=%0d",
                  whitebox_enable ? "white-box" : "black-box",
                  current_epoch, accepted_write_count, accepted_read_count,
                  write_commit_count, read_snapshot_count,
                  write_response_count, read_response_count,
                  b_stall_cycles, r_stall_cycles,
                  buffered_nonzero_side_effect_count, delayed_snapshot_count,
                  same_edge_rw_count,
                  reset_count, violation_count), UVM_NONE)
  endfunction
endclass
