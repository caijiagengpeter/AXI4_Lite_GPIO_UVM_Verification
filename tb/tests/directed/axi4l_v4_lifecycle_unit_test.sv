class axi4l_v4_capture_sink extends axi4l_v4_response_sink;
  axi4l_seq_item responses[$];
  int unsigned put_count;

  virtual task put_response(input axi4l_seq_item rsp);
    responses.push_back(rsp);
    put_count++;
  endtask
endclass

class axi4l_v4_lifecycle_unit_test extends uvm_test;
  `uvm_component_utils(axi4l_v4_lifecycle_unit_test)
  covergroup lifecycle_scenario_cg with function sample(int scenario);
    option.per_instance = 1;
    cp_scenario: coverpoint scenario {
      bins normal_publish = {0}; bins normal_abort_race = {1};
      bins handshake_then_reset = {2}; bins unfinished_abort = {3};
      bins credit_wait_reset = {4}; bins direction_independence = {5};
    }
  endgroup


  function new(string name = "axi4l_v4_lifecycle_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
    lifecycle_scenario_cg = new;
  endfunction

  function void check_condition(bit condition, string message);
    if (!condition)
      `uvm_error("V4_LIFECYCLE_UNIT", message)
  endfunction

  task automatic make_context(axi4l_v4_lifecycle_service service,
                              axi4l_access_e access,
                              int sequence_id,
                              int transaction_id,
                              bit [AXI4L_ADDR_WIDTH-1:0] addr,
                              output axi4l_seq_item req,
                              output axi4l_txn_context ctx);
    req = axi4l_seq_item::type_id::create(
      $sformatf("req_s%0d_t%0d", sequence_id, transaction_id));
    req.access = access;
    req.addr   = addr;
    req.data   = 'h5a5a_1234;
    req.strb   = '1;
    req.prot   = 3'b010;
    req.set_sequence_id(sequence_id);
    req.set_transaction_id(transaction_id);
    // This is existing monitor metadata, distinct from the UVM transaction ID.
    req.transaction_id = transaction_id + 32'h1000;
    service.create_context(req, ctx);
  endtask

  task automatic check_invariant(axi4l_v4_lifecycle_service service,
                                 string point);
    bit ok;
    service.check_invariants(ok);
    check_condition(ok, $sformatf("credit invariant failed at %s", point));
  endtask

  task automatic mark_request_accepted(axi4l_v4_lifecycle_service service,
                                       axi4l_txn_context ctx,
                                       longint unsigned first_cycle);
    bit first_recorded;
    bit second_recorded;
    if (ctx.get_access() == AXI4L_WRITE) begin
      service.mark_channel_handshake(ctx, AXI4L_CHANNEL_AW, ctx.get_epoch(),
                                     1'b1, first_cycle, first_recorded);
      service.mark_channel_handshake(ctx, AXI4L_CHANNEL_W, ctx.get_epoch(),
                                     1'b1, first_cycle + 1, second_recorded);
      check_condition(first_recorded && second_recorded && ctx.get_request_accepted(),
            "write request acceptance setup failed");
    end else begin
      service.mark_channel_handshake(ctx, AXI4L_CHANNEL_AR, ctx.get_epoch(),
                                     1'b1, first_cycle, first_recorded);
      check_condition(first_recorded && ctx.get_request_accepted(),
            "read request acceptance setup failed");
    end
  endtask

  task automatic test_normal_publish_and_ids();
    axi4l_v4_lifecycle_service service;
    axi4l_v4_capture_sink sink;
    axi4l_seq_item req;
    axi4l_txn_context ctx;
    axi4l_txn_context published;
    bit acquired;
    bit committed;
    bit item_done_won;
    bit normal_won;
    bit duplicate_won;
    bit released_again;
    longint unsigned epoch;
    bit reset_active;
    int unsigned write_available, read_available;
    int unsigned write_owned, read_owned, registry_count, terminal_depth;

    service = new("normal_service", 2, 2);
    sink = new();
    make_context(service, AXI4L_WRITE, 11, 101, 'h10, req, ctx);
    check_condition(ctx.get_sequence_id_snapshot() == 11, "sequence ID snapshot mismatch");
    check_condition(ctx.get_uvm_transaction_id_snapshot() == 101,
          "transaction ID snapshot mismatch");
    check_condition((ctx.get_addr() == 'h10) && (ctx.get_data() == 'h5a5a_1234),
          "immutable request payload snapshot mismatch");

    service.acquire_credit(ctx, acquired);
    check_condition(acquired && ctx.get_credit_owned(), "normal context did not acquire credit");
    service.mark_dispatch_committed(ctx, ctx.get_epoch(), committed);
    check_condition(committed, "dispatch commit was not accepted");
    service.claim_item_done(ctx, item_done_won);
    check_condition(item_done_won, "first item_done ownership claim failed");
    mark_request_accepted(service, ctx, 40);
    service.record_normal_completion(ctx, ctx.get_epoch(), 1'b1,
                                     2'b00, 'x, 42, normal_won);
    check_condition(normal_won, "normal terminal claim failed");
    service.claim_terminal(ctx, AXI4L_TERMINAL_NORMAL, duplicate_won);
    check_condition(!duplicate_won, "duplicate NORMAL terminal claim succeeded");

    service.publish_next(sink, published);
    check_condition(published == ctx, "publisher returned the wrong context");
    check_condition(sink.put_count == 1, "normal response was not published exactly once");
    check_condition(sink.responses[0].get_sequence_id() == 11,
          "published response lost sequence ID");
    check_condition(sink.responses[0].get_transaction_id() == 101,
          "published response lost transaction ID");
    check_condition(!sink.responses[0].transaction_aborted &&
          (sink.responses[0].resp === 2'b00) &&
          (sink.responses[0].rdata === 'x),
          "normal write response snapshot is invalid");
    service.release_credit_once(ctx, released_again);
    check_condition(!released_again, "credit double release guard failed");
    service.get_snapshot(epoch, reset_active, write_available, read_available,
                         write_owned, read_owned, registry_count, terminal_depth);
    check_condition((write_available == 2) && (write_owned == 0) &&
          (registry_count == 0) && (terminal_depth == 0),
          "normal publication did not release/retire exactly once");
    check_invariant(service, "normal publish");
    lifecycle_scenario_cg.sample(0);
  endtask

  task automatic test_normal_abort_race();
    axi4l_v4_lifecycle_service service;
    axi4l_v4_capture_sink sink;
    axi4l_seq_item req;
    axi4l_txn_context ctx;
    axi4l_txn_context published;
    bit acquired;
    bit item_done_won;
    bit normal_won;
    bit abort_won;

    service = new("race_service", 1, 1);
    sink = new();
    make_context(service, AXI4L_READ, 12, 102, 'h14, req, ctx);
    service.acquire_credit(ctx, acquired);
    check_condition(acquired, "race context did not acquire credit");
    service.claim_item_done(ctx, item_done_won);
    check_condition(item_done_won, "race context item_done ownership claim failed");
    mark_request_accepted(service, ctx, 50);
    fork
      service.record_normal_completion(ctx, ctx.get_epoch(), 1'b1,
                                       2'b00, 'hcafe_beef, 51, normal_won);
      service.claim_terminal(ctx, AXI4L_TERMINAL_ABORTED, abort_won);
    join
    check_condition(normal_won ^ abort_won,
          "NORMAL vs ABORT race did not produce exactly one winner");
    check_condition(ctx.get_terminal() != AXI4L_TERMINAL_ACTIVE,
          "race winner did not set terminal state");
    service.publish_next(sink, published);
    check_condition(sink.put_count == 1, "race produced missing/duplicate response");
    check_invariant(service, "terminal race");
    lifecycle_scenario_cg.sample(1);
  endtask

  task automatic test_handshake_then_reset_stays_normal();
    axi4l_v4_lifecycle_service service;
    axi4l_v4_capture_sink sink;
    axi4l_seq_item req;
    axi4l_txn_context ctx;
    axi4l_txn_context published;
    bit acquired;
    bit item_done_won;
    bit recorded;
    bit normal_won;
    bit abort_won;
    longint unsigned new_epoch;

    service = new("handshake_reset_service", 1, 1);
    sink = new();
    make_context(service, AXI4L_READ, 13, 103, 'h18, req, ctx);
    service.acquire_credit(ctx, acquired);
    service.claim_item_done(ctx, item_done_won);
    mark_request_accepted(service, ctx, 59);
    service.record_response_handshake(ctx, ctx.get_epoch(), 1'b1,
                                      2'b00, 'h1234_5678, 60, recorded);
    check_condition(acquired && item_done_won && recorded,
          "pre-reset R handshake setup was not completed");
    service.begin_reset_and_abort(new_epoch);
    check_condition(ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE,
          "reset converted an already handshaken response to ABORT");
    service.claim_terminal(ctx, AXI4L_TERMINAL_ABORTED, abort_won);
    check_condition(!abort_won, "ABORT won after response handshake");
    service.claim_terminal(ctx, AXI4L_TERMINAL_NORMAL, normal_won);
    check_condition(normal_won, "recorded response could not claim NORMAL after reset");
    service.publish_next(sink, published);
    check_condition(!sink.responses[0].transaction_aborted &&
          (sink.responses[0].rdata === 'h1234_5678),
          "post-reset publication did not preserve normal R snapshot");
    check_invariant(service, "handshake then reset");
    lifecycle_scenario_cg.sample(2);
  endtask

  task automatic test_unfinished_reset_abort_and_item_done();
    axi4l_v4_lifecycle_service service;
    axi4l_v4_capture_sink sink;
    axi4l_seq_item req;
    axi4l_txn_context ctx;
    axi4l_txn_context published;
    bit acquired;
    bit first_item_done;
    bit second_item_done;
    bit worker_valid;
    bit old_channel_recorded;
    bit publisher_done;
    longint unsigned old_epoch;
    longint unsigned new_epoch;

    service = new("abort_service", 1, 1);
    sink = new();
    make_context(service, AXI4L_WRITE, 14, 104, 'h1c, req, ctx);
    old_epoch = ctx.get_epoch();
    service.acquire_credit(ctx, acquired);
    service.begin_reset_and_abort(new_epoch);
    check_condition(acquired && ctx.get_cancel_requested() &&
          (ctx.get_terminal() == AXI4L_TERMINAL_ABORTED),
          "unfinished reset context did not become ABORTED");
    check_condition(!ctx.get_item_done_sent(),
          "Reset Coordinator incorrectly took Dispatcher item_done ownership");
    publisher_done = 1'b0;
    fork
      begin
        service.publish_next(sink, published);
        publisher_done = 1'b1;
      end
    join_none
    #1ns;
    check_condition(!publisher_done && (sink.put_count == 0),
          "Publisher overtook Dispatcher item_done");
    service.claim_item_done(ctx, first_item_done);
    service.claim_item_done(ctx, second_item_done);
    check_condition(first_item_done && !second_item_done,
          "item_done ownership was not exactly once");
    wait (publisher_done);
    service.worker_entry_valid(ctx, old_epoch, worker_valid);
    check_condition(!worker_valid, "old-epoch worker entry remained driveable");
    service.mark_channel_handshake(ctx, AXI4L_CHANNEL_AW, old_epoch,
                                   1'b1, 70, old_channel_recorded);
    check_condition(!old_channel_recorded && !ctx.get_aw_handshake(),
          "stale worker recorded a new handshake");
    check_condition(sink.responses[0].transaction_aborted &&
          (sink.responses[0].resp === 'x) &&
          (sink.responses[0].rdata === 'x),
          "synthetic abort response violated four-state contract");
    check_invariant(service, "unfinished reset abort");
    lifecycle_scenario_cg.sample(3);
  endtask

  task automatic test_credit_wait_reset_without_phantom_release();
    axi4l_v4_lifecycle_service service;
    axi4l_v4_capture_sink sink;
    axi4l_seq_item req_a, req_b;
    axi4l_txn_context ctx_a, ctx_b;
    axi4l_txn_context published;
    bit got_a, got_b;
    bit waiter_done;
    bit item_done_a, item_done_b;
    longint unsigned new_epoch;
    longint unsigned epoch;
    bit reset_active;
    int unsigned write_available, read_available;
    int unsigned write_owned, read_owned, registry_count, terminal_depth;

    service = new("credit_wait_reset_service", 1, 1);
    sink = new();
    make_context(service, AXI4L_WRITE, 15, 105, 'h20, req_a, ctx_a);
    make_context(service, AXI4L_WRITE, 16, 106, 'h24, req_b, ctx_b);
    service.acquire_credit(ctx_a, got_a);
    check_condition(got_a, "credit-wait reset holder did not acquire credit");
    waiter_done = 1'b0;
    fork
      begin
        service.acquire_credit(ctx_b, got_b);
        waiter_done = 1'b1;
      end
    join_none
    #1ns;
    check_condition(!waiter_done, "credit-wait reset request did not block");
    service.begin_reset_and_abort(new_epoch);
    wait (waiter_done);
    check_condition(!got_b && !ctx_b.get_credit_owned(),
          "reset credit waiter incorrectly acquired/owned a token");
    service.claim_item_done(ctx_a, item_done_a);
    service.claim_item_done(ctx_b, item_done_b);
    check_condition(item_done_a && item_done_b,
          "credit-wait reset item_done ownership failed");
    service.publish_next(sink, published);
    service.publish_next(sink, published);
    service.get_snapshot(epoch, reset_active, write_available, read_available,
                         write_owned, read_owned, registry_count, terminal_depth);
    check_condition((write_available == 1) && (write_owned == 0) &&
          (registry_count == 0) && (sink.put_count == 2),
          "no-credit abort created a phantom token or lost a response");
    check_invariant(service, "credit-wait reset");
    lifecycle_scenario_cg.sample(4);
  endtask

  task automatic test_credit_wait_and_direction_independence();
    axi4l_v4_lifecycle_service service;
    axi4l_v4_capture_sink sink;
    axi4l_seq_item req_a, req_b, req_c, req_r;
    axi4l_txn_context ctx_a, ctx_b, ctx_c, ctx_r;
    axi4l_txn_context published;
    bit got_a, got_b, got_c, got_r;
    bit waiter_done;
    bit item_done_a, item_done_b, item_done_c, item_done_r;
    bit normal_won;
    bit valid_new;
    bit new_aw_recorded;
    longint unsigned new_epoch;
    longint unsigned epoch;
    bit reset_active;
    int unsigned write_available, read_available;
    int unsigned write_owned, read_owned, registry_count, terminal_depth;

    service = new("credit_service", 2, 2);
    sink = new();
    make_context(service, AXI4L_WRITE, 21, 201, 'h20, req_a, ctx_a);
    make_context(service, AXI4L_WRITE, 22, 202, 'h24, req_b, ctx_b);
    make_context(service, AXI4L_WRITE, 23, 203, 'h28, req_c, ctx_c);
    make_context(service, AXI4L_READ,  24, 204, 'h2c, req_r, ctx_r);
    service.acquire_credit(ctx_a, got_a);
    service.acquire_credit(ctx_b, got_b);
    service.acquire_credit(ctx_r, got_r);
    service.claim_item_done(ctx_a, item_done_a);
    service.claim_item_done(ctx_b, item_done_b);
    service.claim_item_done(ctx_r, item_done_r);
    check_condition(got_a && got_b && got_r,
          "write saturation incorrectly blocked independent read credit");
    service.get_snapshot(epoch, reset_active, write_available, read_available,
                         write_owned, read_owned, registry_count, terminal_depth);
    check_condition((write_available == 0) && (write_owned == 2) &&
          (read_available == 1) && (read_owned == 1),
          "saturated credit snapshot is inconsistent");

    waiter_done = 1'b0;
    fork
      begin
        service.acquire_credit(ctx_c, got_c);
        waiter_done = 1'b1;
      end
    join_none
    #1ns;
    check_condition(!waiter_done, "third write did not wait at max_write=2");
    mark_request_accepted(service, ctx_a, 78);
    service.record_normal_completion(ctx_a, ctx_a.get_epoch(), 1'b1,
                                     2'b00, 'x, 80, normal_won);
    check_condition(normal_won, "credit-release source did not become NORMAL");
    service.publish_next(sink, published);
    wait (waiter_done);
    check_condition(got_c && ctx_c.get_credit_owned(),
          "waiting write did not acquire the released credit");
    service.claim_item_done(ctx_c, item_done_c);
    check_condition(item_done_a && item_done_b && item_done_c && item_done_r,
          "credit test item_done ownership setup failed");
    check_invariant(service, "waiter acquired released credit");

    service.begin_reset_and_abort(new_epoch);
    service.publish_next(sink, published);
    service.publish_next(sink, published);
    service.publish_next(sink, published);
    check_condition(sink.put_count == 4,
          "credit test did not publish one normal plus three aborts");
    check_invariant(service, "credit cleanup");

    service.end_reset();
    make_context(service, AXI4L_WRITE, 25, 205, 'h30, req_a, ctx_a);
    service.worker_entry_valid(ctx_a, new_epoch, valid_new);
    service.mark_channel_handshake(ctx_a, AXI4L_CHANNEL_AW, new_epoch,
                                   1'b1, 90, new_aw_recorded);
    check_condition(valid_new && new_aw_recorded && ctx_a.get_aw_handshake(),
          "new-epoch worker entry was not accepted after reset release");
    service.begin_reset_and_abort(new_epoch);
    service.claim_item_done(ctx_a, item_done_a);
    check_condition(item_done_a, "new-epoch reset context item_done claim failed");
    service.publish_next(sink, published);
    check_invariant(service, "new epoch cleanup");
    lifecycle_scenario_cg.sample(5);
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_normal_publish_and_ids();
    test_normal_abort_race();
    test_handshake_then_reset_stays_normal();
    test_unfinished_reset_abort_and_item_done();
    test_credit_wait_reset_without_phantom_release();
    test_credit_wait_and_direction_independence();
    `uvm_info("V4_LIFECYCLE_UNIT",
              "all focused lifecycle scenarios completed", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
