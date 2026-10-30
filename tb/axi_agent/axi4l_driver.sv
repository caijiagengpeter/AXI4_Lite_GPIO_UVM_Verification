class axi4l_driver extends uvm_driver #(axi4l_seq_item);
  `uvm_component_utils(axi4l_driver)

  class v4_response_sink extends axi4l_v4_response_sink;
    axi4l_driver owner;
    function new(axi4l_driver owner); this.owner = owner; endfunction
    virtual task put_response(input axi4l_seq_item rsp);
      owner.put_v4_response(rsp);
    endtask
  endclass

  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;

  // Three deliberately distinct operating modes are kept:
  //   legacy/default       - item_done() follows the B/R response;
  //   limited_overlap_mode - v2.1 coverage-only bounded overlap;
  //   pipelined_mode       - v3 ordered request/response decoupling.
  bit transaction_aborted;
  bit limited_overlap_mode;
  bit pipelined_mode;
  bit v4_mode;

  axi4l_v4_lifecycle_service v4_lifecycle;
  v4_response_sink           v4_sink;
  bit v4_aw_quiescent = 1'b1;
  bit v4_w_quiescent  = 1'b1;
  bit v4_ar_quiescent = 1'b1;
  bit v4_b_quiescent  = 1'b1;
  bit v4_r_quiescent  = 1'b1;
  bit v4_waiting_for_credit;
  bit v4_publisher_hold;
  longint unsigned v4_dispatch_count;
  longint unsigned v4_publish_count;
  longint unsigned v4_aw_handshake_count;
  longint unsigned v4_w_handshake_count;
  longint unsigned v4_ar_handshake_count;
  longint unsigned v4_b_handshake_count;
  longint unsigned v4_r_handshake_count;

  mailbox #(axi4l_seq_item) limited_response_mailbox;
  longint unsigned limited_requests_issued;
  longint unsigned limited_responses_completed;

  int unsigned max_write_outstanding = 1;
  int unsigned max_read_outstanding  = 1;
  mailbox #(axi4l_seq_item) pending_write_response_fifo;
  mailbox #(axi4l_seq_item) pending_read_response_fifo;
  semaphore write_credits;
  semaphore read_credits;
  int write_credit_balance;
  int read_credit_balance;
  int unsigned write_outstanding;
  int unsigned read_outstanding;
  longint unsigned v3_write_requests_issued;
  longint unsigned v3_read_requests_issued;
  longint unsigned v3_write_responses_completed;
  longint unsigned v3_read_responses_completed;
  longint unsigned driver_cycle;

  function new(string name = "axi4l_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4l_if #(AXI4L_ADDR_WIDTH,
                                           AXI4L_DATA_WIDTH))::get(
          this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axi4l_driver did not receive its virtual interface")

    void'(uvm_config_db#(bit)::get(this, "", "limited_overlap_mode",
                                   limited_overlap_mode));
    void'(uvm_config_db#(bit)::get(this, "", "pipelined_mode",
                                   pipelined_mode));
    void'(uvm_config_db#(bit)::get(this, "", "v4_mode", v4_mode));
    void'(uvm_config_db#(int unsigned)::get(
      this, "", "max_write_outstanding", max_write_outstanding));
    void'(uvm_config_db#(int unsigned)::get(
      this, "", "max_read_outstanding", max_read_outstanding));

    if ((limited_overlap_mode + pipelined_mode + v4_mode) > 1)
      `uvm_fatal("DRIVER_MODE",
                 "legacy/limited_overlap/pipelined/v4 selections are mutually exclusive")

    if (limited_overlap_mode)
      limited_response_mailbox = new();

    if (pipelined_mode) begin
      if ((max_write_outstanding == 0) || (max_read_outstanding == 0))
        `uvm_fatal("V3_DEPTH", "v3 outstanding depths must both be at least one")
      pending_write_response_fifo = new();
      pending_read_response_fifo  = new();
      write_credits = new(max_write_outstanding);
      read_credits  = new(max_read_outstanding);
      write_credit_balance = max_write_outstanding;
      read_credit_balance  = max_read_outstanding;
    end

    if (v4_mode) begin
      if ((max_write_outstanding == 0) || (max_read_outstanding == 0))
        `uvm_fatal("V4_DEPTH", "v4 outstanding depths must both be at least one")
      v4_lifecycle = new("v4_lifecycle", max_write_outstanding,
                         max_read_outstanding);
      v4_sink = new(this);
    end
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle();
    fork
      count_driver_cycles();
      begin
        if (v4_mode) begin
          `uvm_info("V4_PIPELINED",
            $sformatf("enabled: max_write_outstanding=%0d max_read_outstanding=%0d",
                      max_write_outstanding, max_read_outstanding), UVM_LOW)
          fork
            v4_dispatcher();
            v4_aw_worker();
            v4_w_worker();
            v4_ar_worker();
            v4_b_collector();
            v4_r_collector();
            v4_response_publisher();
            v4_reset_coordinator();
          join
        end else if (pipelined_mode) begin
          `uvm_info("V3_PIPELINED",
            $sformatf("enabled: max_write_outstanding=%0d max_read_outstanding=%0d",
                      max_write_outstanding, max_read_outstanding), UVM_LOW)
          fork
            pipelined_request_loop();
            pipelined_write_response_loop();
            pipelined_read_response_loop();
          join
        end else if (limited_overlap_mode) begin
          `uvm_info("LIMITED_OVERLAP",
                    "enabled request/response decoupling for bounded stall stress",
                    UVM_LOW)
          fork
            limited_request_loop();
            limited_response_loop();
          join
        end else begin
          run_blocking_loop();
        end
      end
    join
  endtask

  task count_driver_cycles();
    forever begin
      @(vif.drv_cb);
      driver_cycle++;
    end
  endtask

  // ----------------------------------------------------------------------
  // v4 channel-level pipeline
  // ----------------------------------------------------------------------

  task put_v4_response(input axi4l_seq_item rsp);
    // Test-only gate used to prove that a NORMAL terminal decision survives
    // reset even when UVM publication has not yet happened.
    wait (!v4_publisher_hold);
    seq_item_port.put_response(rsp);
  endtask

  task v4_dispatcher();
    axi4l_seq_item req;
    axi4l_txn_context ctx;
    bit acquired;
    bit committed;
    bit item_done_claimed;
    bit abort_won;

    forever begin
      do @(vif.drv_cb); while (vif.drv_cb.ARESETN !== 1'b1);
      seq_item_port.get_next_item(req);
      v4_lifecycle.create_context(req, ctx);
      v4_waiting_for_credit = 1'b1;
      v4_lifecycle.acquire_credit(ctx, acquired);
      v4_waiting_for_credit = 1'b0;
      committed = 1'b0;
      if (acquired)
        v4_lifecycle.commit_dispatch(ctx, ctx.get_epoch(), committed);
      if (!committed && (ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE))
        v4_lifecycle.claim_terminal(ctx, AXI4L_TERMINAL_ABORTED, abort_won);

      // The Dispatcher is the sole request-port owner.  Publication is not
      // allowed to observe item_done_sent until the real UVM call returned.
      seq_item_port.item_done();
      v4_lifecycle.claim_item_done(ctx, item_done_claimed);
      if (!item_done_claimed)
        `uvm_fatal("V4_ITEM_DONE", "Dispatcher lost unique item_done ownership")
      if (committed) begin
        v4_dispatch_count++;
        `uvm_info("V4_DISPATCH",
          $sformatf("request_id=%0d order=%0d access=%s epoch=%0d addr=0x%0h",
                    ctx.get_request_id(), ctx.get_order_id(),
                    (ctx.get_access() == AXI4L_WRITE) ? "WRITE" : "READ",
                    ctx.get_epoch(), ctx.get_addr()), UVM_HIGH)
      end
    end
  endtask

  task automatic v4_delay_context(input axi4l_txn_context ctx,
                                  input int unsigned delay_cycles,
                                  output bit live);
    live = 1'b1;
    repeat (delay_cycles) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        live = 1'b0;
        return;
      end
      v4_lifecycle.worker_entry_valid(ctx, ctx.get_epoch(), live);
      if (!live)
        return;
    end
    v4_lifecycle.worker_entry_valid(ctx, ctx.get_epoch(), live);
  endtask

  task v4_aw_worker();
    axi4l_txn_context ctx;
    bit found, live, recorded;
    forever begin
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.AWVALID <= 1'b0;
        v4_aw_quiescent = 1'b1;
        @(vif.drv_cb);
        continue;
      end
      v4_aw_quiescent = 1'b0;
      v4_lifecycle.try_pop_channel(AXI4L_CHANNEL_AW, ctx, found);
      if (!found) begin @(vif.drv_cb); continue; end
      v4_delay_context(ctx, ctx.get_aw_delay(), live);
      if (!live) begin vif.drv_cb.AWVALID <= 1'b0; continue; end
      vif.drv_cb.AWADDR  <= ctx.get_addr();
      vif.drv_cb.AWPROT  <= ctx.get_prot();
      vif.drv_cb.AWVALID <= 1'b1;
      forever begin
        @(vif.drv_cb);
        if (vif.drv_cb.ARESETN !== 1'b1) begin
          vif.drv_cb.AWVALID <= 1'b0; v4_aw_quiescent = 1'b1; break;
        end
        if (vif.drv_cb.AWREADY) begin
          v4_lifecycle.mark_channel_handshake(
            ctx, AXI4L_CHANNEL_AW, ctx.get_epoch(), 1'b1,
            driver_cycle, recorded);
          vif.drv_cb.AWVALID <= 1'b0;
          if (recorded) v4_aw_handshake_count++;
          break;
        end
      end
    end
  endtask

  task v4_w_worker();
    axi4l_txn_context ctx;
    bit found, live, recorded;
    forever begin
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.WVALID <= 1'b0;
        v4_w_quiescent = 1'b1;
        @(vif.drv_cb);
        continue;
      end
      v4_w_quiescent = 1'b0;
      v4_lifecycle.try_pop_channel(AXI4L_CHANNEL_W, ctx, found);
      if (!found) begin @(vif.drv_cb); continue; end
      v4_delay_context(ctx, ctx.get_w_delay(), live);
      if (!live) begin vif.drv_cb.WVALID <= 1'b0; continue; end
      vif.drv_cb.WDATA  <= ctx.get_data();
      vif.drv_cb.WSTRB  <= ctx.get_strb();
      vif.drv_cb.WVALID <= 1'b1;
      forever begin
        @(vif.drv_cb);
        if (vif.drv_cb.ARESETN !== 1'b1) begin
          vif.drv_cb.WVALID <= 1'b0; v4_w_quiescent = 1'b1; break;
        end
        if (vif.drv_cb.WREADY) begin
          v4_lifecycle.mark_channel_handshake(
            ctx, AXI4L_CHANNEL_W, ctx.get_epoch(), 1'b1,
            driver_cycle, recorded);
          vif.drv_cb.WVALID <= 1'b0;
          if (recorded) v4_w_handshake_count++;
          break;
        end
      end
    end
  endtask

  task v4_ar_worker();
    axi4l_txn_context ctx;
    bit found, live, recorded;
    forever begin
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.ARVALID <= 1'b0;
        v4_ar_quiescent = 1'b1;
        @(vif.drv_cb);
        continue;
      end
      v4_ar_quiescent = 1'b0;
      v4_lifecycle.try_pop_channel(AXI4L_CHANNEL_AR, ctx, found);
      if (!found) begin @(vif.drv_cb); continue; end
      v4_delay_context(ctx, ctx.get_ar_delay(), live);
      if (!live) begin vif.drv_cb.ARVALID <= 1'b0; continue; end
      vif.drv_cb.ARADDR  <= ctx.get_addr();
      vif.drv_cb.ARPROT  <= ctx.get_prot();
      vif.drv_cb.ARVALID <= 1'b1;
      forever begin
        @(vif.drv_cb);
        if (vif.drv_cb.ARESETN !== 1'b1) begin
          vif.drv_cb.ARVALID <= 1'b0; v4_ar_quiescent = 1'b1; break;
        end
        if (vif.drv_cb.ARREADY) begin
          v4_lifecycle.mark_channel_handshake(
            ctx, AXI4L_CHANNEL_AR, ctx.get_epoch(), 1'b1,
            driver_cycle, recorded);
          vif.drv_cb.ARVALID <= 1'b0;
          if (recorded) v4_ar_handshake_count++;
          break;
        end
      end
    end
  endtask

  task v4_b_collector();
    axi4l_txn_context ctx;
    bit found, live, won;
    bit unmatched_previous;
    forever begin
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.BREADY <= 1'b0;
        v4_b_quiescent = 1'b1;
        unmatched_previous = 1'b0;
        @(vif.drv_cb);
        continue;
      end
      v4_b_quiescent = 1'b0;
      v4_lifecycle.find_response_candidate(AXI4L_WRITE, ctx, found);
      if (!found) begin
        vif.drv_cb.BREADY <= 1'b0;
        if (vif.drv_cb.BVALID && unmatched_previous)
          `uvm_error("V4_B_ASSOC",
                     "BVALID has no oldest write with completed AW and W")
        unmatched_previous = vif.drv_cb.BVALID;
        @(vif.drv_cb);
        continue;
      end
      unmatched_previous = 1'b0;
      v4_delay_context(ctx, ctx.get_bready_delay(), live);
      if (!live) begin vif.drv_cb.BREADY <= 1'b0; continue; end
      vif.drv_cb.BREADY <= 1'b1;
      forever begin
        @(vif.drv_cb);
        if (vif.drv_cb.ARESETN !== 1'b1) begin
          vif.drv_cb.BREADY <= 1'b0; v4_b_quiescent = 1'b1; break;
        end
        if (vif.drv_cb.BVALID) begin
          v4_lifecycle.record_normal_completion(
            ctx, ctx.get_epoch(), 1'b1, vif.drv_cb.BRESP, 'x,
            driver_cycle, won);
          vif.drv_cb.BREADY <= 1'b0;
          if (!won)
            `uvm_error("V4_B_GATE", "B handshake lost the terminal gate")
          else begin
            v4_b_handshake_count++;
            `uvm_info("V4_B_HANDSHAKE",
              $sformatf("request_id=%0d order=%0d cycle=%0d BRESP=%02b",
                        ctx.get_request_id(), ctx.get_order_id(),
                        driver_cycle, vif.drv_cb.BRESP), UVM_HIGH)
          end
          break;
        end
      end
    end
  endtask

  task v4_r_collector();
    axi4l_txn_context ctx;
    bit found, live, won;
    bit unmatched_previous;
    forever begin
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.RREADY <= 1'b0;
        v4_r_quiescent = 1'b1;
        unmatched_previous = 1'b0;
        @(vif.drv_cb);
        continue;
      end
      v4_r_quiescent = 1'b0;
      v4_lifecycle.find_response_candidate(AXI4L_READ, ctx, found);
      if (!found) begin
        vif.drv_cb.RREADY <= 1'b0;
        if (vif.drv_cb.RVALID && unmatched_previous)
          `uvm_error("V4_R_ASSOC",
                     "RVALID has no oldest read with a completed AR")
        unmatched_previous = vif.drv_cb.RVALID;
        @(vif.drv_cb);
        continue;
      end
      unmatched_previous = 1'b0;
      v4_delay_context(ctx, ctx.get_rready_delay(), live);
      if (!live) begin vif.drv_cb.RREADY <= 1'b0; continue; end
      vif.drv_cb.RREADY <= 1'b1;
      forever begin
        @(vif.drv_cb);
        if (vif.drv_cb.ARESETN !== 1'b1) begin
          vif.drv_cb.RREADY <= 1'b0; v4_r_quiescent = 1'b1; break;
        end
        if (vif.drv_cb.RVALID) begin
          v4_lifecycle.record_normal_completion(
            ctx, ctx.get_epoch(), 1'b1, vif.drv_cb.RRESP,
            vif.drv_cb.RDATA, driver_cycle, won);
          vif.drv_cb.RREADY <= 1'b0;
          if (!won)
            `uvm_error("V4_R_GATE", "R handshake lost the terminal gate")
          else begin
            v4_r_handshake_count++;
            `uvm_info("V4_R_HANDSHAKE",
              $sformatf("request_id=%0d order=%0d cycle=%0d RRESP=%02b RDATA=0x%0h",
                        ctx.get_request_id(), ctx.get_order_id(), driver_cycle,
                        vif.drv_cb.RRESP, vif.drv_cb.RDATA), UVM_HIGH)
          end
          break;
        end
      end
    end
  endtask

  task v4_response_publisher();
    axi4l_txn_context ctx;
    forever begin
      v4_lifecycle.publish_next(v4_sink, ctx);
      v4_publish_count++;
      `uvm_info("V4_PUBLISH",
        $sformatf("request_id=%0d order=%0d terminal=%s seq_id=%0d tr_id=%0d",
                  ctx.get_request_id(), ctx.get_order_id(),
                  (ctx.get_terminal() == AXI4L_TERMINAL_NORMAL)
                    ? "NORMAL" : "ABORTED",
                  ctx.get_sequence_id_snapshot(),
                  ctx.get_uvm_transaction_id_snapshot()), UVM_HIGH)
    end
  endtask

  task v4_reset_coordinator();
    bit reset_seen;
    longint unsigned new_epoch;
    reset_seen = 1'b0;
    forever begin
      @(vif.drv_cb);
      if ((vif.drv_cb.ARESETN !== 1'b1) && !reset_seen) begin
        reset_seen = 1'b1;
        v4_lifecycle.begin_reset_and_abort(new_epoch);
        wait (v4_aw_quiescent && v4_w_quiescent && v4_ar_quiescent &&
              v4_b_quiescent && v4_r_quiescent);
        `uvm_info("V4_RESET_BARRIER",
          $sformatf("epoch=%0d all five pin owners quiescent", new_epoch),
          UVM_HIGH)
      end
      if ((vif.drv_cb.ARESETN === 1'b1) && reset_seen) begin
        v4_lifecycle.end_reset();
        reset_seen = 1'b0;
      end
    end
  endtask

  task wait_for_v4_idle();
    longint unsigned epoch;
    bit reset_active;
    int unsigned wa, ra, wo, ro, registry_count, terminal_depth;
    int unsigned aw_depth, w_depth, ar_depth;
    bit done, invariant_ok;
    if (!v4_mode)
      `uvm_fatal("V4_PIPELINED", "wait_for_v4_idle called while v4 is disabled")
    done = 1'b0;
    while (!done) begin
      v4_lifecycle.get_snapshot(epoch, reset_active, wa, ra, wo, ro,
                                registry_count, terminal_depth);
      v4_lifecycle.get_queue_snapshot(aw_depth, w_depth, ar_depth);
      done = !reset_active && (registry_count == 0) &&
             (terminal_depth == 0) && (wo == 0) && (ro == 0) &&
             (aw_depth == 0) && (w_depth == 0) && (ar_depth == 0) &&
             !v4_waiting_for_credit;
      if (!done) @(vif.drv_cb);
    end
    v4_lifecycle.check_invariants(invariant_ok);
    if (!invariant_ok)
      `uvm_fatal("V4_CREDIT_INVARIANT", "available + owned != configured maximum")
  endtask

  // Legacy blocking path.  This remains the default so existing v2 tests keep
  // their original request-plus-response item_done() contract.
  task run_blocking_loop();
    axi4l_seq_item req;

    forever begin
      wait_for_reset_release();
      seq_item_port.get_next_item(req);
      req.resp                = 'x;
      req.rdata               = 'x;
      req.transaction_aborted = 1'b0;
      transaction_aborted     = 0;

      case (req.access)
        AXI4L_WRITE: drive_write(req);
        AXI4L_READ:  drive_read(req);
        default:     `uvm_error("BAD_ACCESS", "Unknown AXI4-Lite access type")
      endcase

      req.transaction_aborted = transaction_aborted;
      drive_idle();
      seq_item_port.item_done();
    end
  endtask

  // v2.1 coverage-only overlap path, preserved unchanged in behavior.
  task limited_request_loop();
    axi4l_seq_item req;

    forever begin
      wait_for_reset_release();
      seq_item_port.get_next_item(req);
      req.resp                = 'x;
      req.rdata               = 'x;
      req.transaction_aborted = 1'b0;
      transaction_aborted     = 0;

      case (req.access)
        AXI4L_WRITE: drive_write_request(req);
        AXI4L_READ:  drive_read_request(req);
        default:     `uvm_error("BAD_ACCESS", "Unknown AXI4-Lite access type")
      endcase

      if (!transaction_aborted) begin
        limited_requests_issued++;
        limited_response_mailbox.put(req);
      end
      req.transaction_aborted = transaction_aborted;
      seq_item_port.item_done();
    end
  endtask

  task limited_response_loop();
    axi4l_seq_item req;
    bit response_aborted;

    forever begin
      limited_response_mailbox.get(req);
      response_aborted = 0;
      case (req.access)
        AXI4L_WRITE: collect_write_response(req, response_aborted);
        AXI4L_READ:  collect_read_response(req, response_aborted);
        default:     `uvm_error("BAD_ACCESS", "Unknown AXI4-Lite access type")
      endcase
      limited_responses_completed++;
    end
  endtask

  task wait_for_limited_idle();
    if (!limited_overlap_mode)
      `uvm_fatal("LIMITED_OVERLAP",
                 "wait_for_limited_idle called while stress mode is disabled")
    wait (limited_requests_issued == limited_responses_completed);
  endtask

  // v3 formal pipelined path.  A credit is reserved before request-side
  // driving.  A write becomes pending only after both AW and W handshakes; a
  // read becomes pending after AR.  item_done() then releases the request,
  // while independent collectors retain context until B/R completes.
  task pipelined_request_loop();
    axi4l_seq_item req;
    axi4l_seq_item req_ctx;
    bit credit_acquired;

    forever begin
      wait_for_pipelined_reset_release();
      seq_item_port.get_next_item(req);
      if (!$cast(req_ctx, req.clone()))
        `uvm_fatal("V3_REQ_CLONE", "Failed to clone pipelined request context")
      // Explicitly retain the UVM routing IDs; object copy alone is not the
      // response association contract.
      req_ctx.set_id_info(req);
      req_ctx.resp                = 'x;
      req_ctx.rdata               = 'x;
      req_ctx.transaction_aborted = 1'b0;
      transaction_aborted         = 0;

      case (req_ctx.access)
        AXI4L_WRITE: begin
          acquire_pipelined_credit(write_credits, credit_acquired,
                                   transaction_aborted);
          if (credit_acquired)
            write_credit_balance--;
          if (!transaction_aborted)
            drive_write_request(req_ctx);
          if (transaction_aborted) begin
            req_ctx.transaction_aborted = 1'b1;
            if (credit_acquired) begin
              write_credits.put(1);
              write_credit_balance++;
            end
            // This request has already left the sequencer.  Release its
            // request-side ownership exactly once before routing the single
            // synthetic abort response back to the originating sequence.
            seq_item_port.item_done();
            publish_v3_response(req_ctx);
          end else begin
            req_ctx.accept_cycle = (req_ctx.aw_cycle > req_ctx.w_cycle)
                                 ? req_ctx.aw_cycle : req_ctx.w_cycle;
            write_outstanding++;
            v3_write_requests_issued++;
            pending_write_response_fifo.put(req_ctx);
            `uvm_info("V3_REQ",
              $sformatf("WRITE issue_cycle=%0d AW=%0d W=%0d addr=0x%0h outstanding=%0d/%0d seq_id=%0d tr_id=%0d",
                        req_ctx.accept_cycle, req_ctx.aw_cycle, req_ctx.w_cycle,
                        req_ctx.addr, write_outstanding,
                        max_write_outstanding, req_ctx.get_sequence_id(),
                        req_ctx.get_transaction_id()), UVM_NONE)
            // In v3 this means request-side ownership has transferred; it is
            // intentionally not complete AXI transaction retirement.
            seq_item_port.item_done();
          end
        end

        AXI4L_READ: begin
          acquire_pipelined_credit(read_credits, credit_acquired,
                                   transaction_aborted);
          if (credit_acquired)
            read_credit_balance--;
          if (!transaction_aborted)
            drive_read_request(req_ctx);
          if (transaction_aborted) begin
            req_ctx.transaction_aborted = 1'b1;
            if (credit_acquired) begin
              read_credits.put(1);
              read_credit_balance++;
            end
            seq_item_port.item_done();
            publish_v3_response(req_ctx);
          end else begin
            read_outstanding++;
            v3_read_requests_issued++;
            pending_read_response_fifo.put(req_ctx);
            `uvm_info("V3_REQ",
              $sformatf("READ issue_cycle=%0d addr=0x%0h outstanding=%0d/%0d seq_id=%0d tr_id=%0d",
                        req_ctx.accept_cycle, req_ctx.addr, read_outstanding,
                        max_read_outstanding, req_ctx.get_sequence_id(),
                        req_ctx.get_transaction_id()), UVM_NONE)
            seq_item_port.item_done();
          end
        end

        default: begin
          `uvm_error("BAD_ACCESS", "Unknown AXI4-Lite access type")
          seq_item_port.item_done();
        end
      endcase
    end
  endtask

  // A blocking semaphore get cannot observe reset.  In particular, a request
  // already fetched with get_next_item() could otherwise wait for a collector
  // to return a credit during reset, then survive into the next reset epoch.
  // Polling try_get at clock boundaries makes that request abortable and also
  // records whether there is a credit to return on the abort path.
  task automatic acquire_pipelined_credit(semaphore credits,
                                            output bit acquired,
                                            output bit aborted);
    acquired = 1'b0;
    aborted  = 1'b0;
    forever begin
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        aborted = 1'b1;
        return;
      end
      if (credits.try_get(1)) begin
        acquired = 1'b1;
        return;
      end
      @(vif.drv_cb);
    end
  endtask

  task pipelined_write_response_loop();
    axi4l_seq_item req_ctx;
    bit response_aborted;

    forever begin
      pending_write_response_fifo.get(req_ctx);
      collect_write_response(req_ctx, response_aborted);
      req_ctx.transaction_aborted = response_aborted;
      req_ctx.response_cycle      = driver_cycle;
      write_outstanding--;
      v3_write_responses_completed++;
      write_credits.put(1);
      write_credit_balance++;
      `uvm_info("V3_RSP",
        $sformatf("WRITE response_cycle=%0d addr=0x%0h BRESP=%02b aborted=%0b outstanding=%0d/%0d seq_id=%0d tr_id=%0d",
                  req_ctx.response_cycle, req_ctx.addr, req_ctx.resp,
                  req_ctx.transaction_aborted, write_outstanding,
                  max_write_outstanding, req_ctx.get_sequence_id(),
                  req_ctx.get_transaction_id()), UVM_NONE)
      publish_v3_response(req_ctx);
    end
  endtask

  task pipelined_read_response_loop();
    axi4l_seq_item req_ctx;
    bit response_aborted;

    forever begin
      pending_read_response_fifo.get(req_ctx);
      collect_read_response(req_ctx, response_aborted);
      req_ctx.transaction_aborted = response_aborted;
      req_ctx.response_cycle      = driver_cycle;
      read_outstanding--;
      v3_read_responses_completed++;
      read_credits.put(1);
      read_credit_balance++;
      `uvm_info("V3_RSP",
        $sformatf("READ response_cycle=%0d addr=0x%0h RDATA=0x%08h RRESP=%02b aborted=%0b outstanding=%0d/%0d seq_id=%0d tr_id=%0d",
                  req_ctx.response_cycle, req_ctx.addr, req_ctx.rdata,
                  req_ctx.resp, req_ctx.transaction_aborted, read_outstanding,
                  max_read_outstanding, req_ctx.get_sequence_id(),
                  req_ctx.get_transaction_id()), UVM_NONE)
      publish_v3_response(req_ctx);
    end
  endtask

  task automatic publish_v3_response(axi4l_seq_item req_ctx);
    axi4l_seq_item rsp;
    if (!$cast(rsp, req_ctx.clone()))
      `uvm_fatal("V3_RSP_CLONE", "Failed to clone pipelined response")
    // set_id_info() is the standard UVM response association mechanism.  It
    // preserves both sequence_id and transaction_id for get_response().
    rsp.set_id_info(req_ctx);
    if (rsp.response_cycle == 0)
      rsp.response_cycle = driver_cycle;
    seq_item_port.put_response(rsp);
  endtask

  task wait_for_pipelined_idle();
    if (!pipelined_mode)
      `uvm_fatal("V3_PIPELINED",
                 "wait_for_pipelined_idle called while v3 mode is disabled")
    wait ((write_outstanding == 0) && (read_outstanding == 0) &&
          (v3_write_requests_issued == v3_write_responses_completed) &&
          (v3_read_requests_issued == v3_read_responses_completed));
  endtask

  task wait_for_reset_release();
    while (vif.drv_cb.ARESETN !== 1'b1) begin
      drive_idle();
      @(vif.drv_cb);
    end
  endtask

  task wait_for_pipelined_reset_release();
    while (vif.drv_cb.ARESETN !== 1'b1) begin
      // BREADY and RREADY belong exclusively to their collectors in v3.
      drive_request_idle();
      @(vif.drv_cb);
    end
  endtask

  function void drive_request_idle();
    vif.drv_cb.AWADDR  <= '0;
    vif.drv_cb.AWPROT  <= '0;
    vif.drv_cb.AWVALID <= 1'b0;
    vif.drv_cb.WDATA   <= '0;
    vif.drv_cb.WSTRB   <= '0;
    vif.drv_cb.WVALID  <= 1'b0;
    vif.drv_cb.ARADDR  <= '0;
    vif.drv_cb.ARPROT  <= '0;
    vif.drv_cb.ARVALID <= 1'b0;
  endfunction

  function void drive_idle();
    drive_request_idle();
    vif.drv_cb.BREADY  <= 1'b0;
    vif.drv_cb.RREADY  <= 1'b0;
  endfunction

  task automatic drive_aw(axi4l_seq_item tr);
    repeat (tr.aw_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        transaction_aborted = 1;
        return;
      end
    end

    vif.drv_cb.AWADDR  <= tr.addr;
    vif.drv_cb.AWPROT  <= tr.prot;
    vif.drv_cb.AWVALID <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.AWVALID <= 1'b0;
        transaction_aborted = 1;
        return;
      end
    end while (!vif.drv_cb.AWREADY);
    tr.aw_cycle = driver_cycle;
    vif.drv_cb.AWVALID <= 1'b0;
  endtask

  task automatic drive_w(axi4l_seq_item tr);
    repeat (tr.w_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        transaction_aborted = 1;
        return;
      end
    end

    vif.drv_cb.WDATA  <= tr.data;
    vif.drv_cb.WSTRB  <= tr.strb;
    vif.drv_cb.WVALID <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.WVALID <= 1'b0;
        transaction_aborted = 1;
        return;
      end
    end while (!vif.drv_cb.WREADY);
    tr.w_cycle = driver_cycle;
    vif.drv_cb.WVALID <= 1'b0;
  endtask

  task automatic drive_write_request(axi4l_seq_item tr);
    // AXI deliberately permits these channels to complete in either order.
    fork
      drive_aw(tr);
      drive_w(tr);
    join
  endtask

  task automatic collect_write_response(axi4l_seq_item tr,
                                        output bit aborted);
    aborted = 0;
    if (vif.drv_cb.ARESETN !== 1'b1) begin
      vif.drv_cb.BREADY <= 1'b0;
      aborted = 1;
      return;
    end

    repeat (tr.bready_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.BREADY <= 1'b0;
        aborted = 1;
        return;
      end
    end

    vif.drv_cb.BREADY <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.BREADY <= 1'b0;
        aborted = 1;
        return;
      end
    end while (!vif.drv_cb.BVALID);

    tr.resp = vif.drv_cb.BRESP;
    vif.drv_cb.BREADY <= 1'b0;
  endtask

  task automatic drive_write(axi4l_seq_item tr);
    bit response_aborted;

    drive_write_request(tr);
    if (transaction_aborted)
      return;
    tr.accept_cycle = (tr.aw_cycle > tr.w_cycle) ? tr.aw_cycle : tr.w_cycle;
    collect_write_response(tr, response_aborted);
    if (response_aborted)
      transaction_aborted = 1;
    tr.response_cycle = driver_cycle;
  endtask

  task automatic drive_read_request(axi4l_seq_item tr);
    repeat (tr.ar_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        transaction_aborted = 1;
        return;
      end
    end

    vif.drv_cb.ARADDR  <= tr.addr;
    vif.drv_cb.ARPROT  <= tr.prot;
    vif.drv_cb.ARVALID <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.ARVALID <= 1'b0;
        transaction_aborted = 1;
        return;
      end
    end while (!vif.drv_cb.ARREADY);
    tr.accept_cycle = driver_cycle;
    vif.drv_cb.ARVALID <= 1'b0;
  endtask

  task automatic collect_read_response(axi4l_seq_item tr,
                                       output bit aborted);
    aborted = 0;
    if (vif.drv_cb.ARESETN !== 1'b1) begin
      vif.drv_cb.RREADY <= 1'b0;
      aborted = 1;
      return;
    end

    repeat (tr.rready_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.RREADY <= 1'b0;
        aborted = 1;
        return;
      end
    end

    vif.drv_cb.RREADY <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.RREADY <= 1'b0;
        aborted = 1;
        return;
      end
    end while (!vif.drv_cb.RVALID);

    tr.rdata = vif.drv_cb.RDATA;
    tr.resp  = vif.drv_cb.RRESP;
    vif.drv_cb.RREADY <= 1'b0;
  endtask

  task automatic drive_read(axi4l_seq_item tr);
    bit response_aborted;

    drive_read_request(tr);
    if (transaction_aborted)
      return;
    collect_read_response(tr, response_aborted);
    if (response_aborted)
      transaction_aborted = 1;
    tr.response_cycle = driver_cycle;
  endtask
endclass
