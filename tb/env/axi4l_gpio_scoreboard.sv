class axi4l_gpio_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(axi4l_gpio_scoreboard)

  localparam bit [1:0] AXI_OKAY = 2'b00;

  // A GPIO output write has both an AXI response and a pin-level side effect.
  // Keep the latter as a separate timed expectation so that every write can be
  // tied back to its transaction and checked on the intended sampled cycle.
  typedef struct {
    longint unsigned    due_cycle;      // GPIO sample cycle to check.
    longint unsigned    transaction_id; // AXI write that created this event.
    bit [GPIO_NOUT-1:0] expected;       // Expected o_gpio value on that cycle.
  } gpio_expected_t;

  // Three monitor streams enter the scoreboard through independent analysis
  // implementations.  The AXI request stream drives the reference model, the
  // AXI response stream supplies actual B/R results, and the GPIO stream is the
  // cycle-by-cycle observation point for reset, inputs, o_gpio, and o_int.
  uvm_analysis_imp_axi_req #(axi4l_seq_item,
                             axi4l_gpio_scoreboard) axi_req_imp;
  uvm_analysis_imp_axi_rsp #(axi4l_seq_item,
                             axi4l_gpio_scoreboard) axi_rsp_imp;
  uvm_analysis_imp_gpio   #(gpio_observation,
                            axi4l_gpio_scoreboard) gpio_imp;

  // Requests wait here until the GPIO sample for their acceptance cycle is
  // processed.  This makes the sample cycle the single timing reference used
  // to advance the model.
  axi4l_seq_item request_events[$];

  // Expected queues are predictions made from accepted requests.  Pending
  // queues contain actual responses already observed by the AXI monitor.
  // Keeping both sides allows callbacks to arrive in either order.
  axi4l_seq_item expected_write_responses[$];
  axi4l_seq_item expected_read_responses[$];
  axi4l_seq_item pending_write_responses[$];
  axi4l_seq_item pending_read_responses[$];

  // One entry per output write: the expected pin value and when to observe it.
  gpio_expected_t expected_gpio_events[$];

  // The newest GPIO observation is held for one callback; see write_gpio().
  gpio_observation delayed_gpio_sample;
  bit              have_delayed_gpio_sample;

  // Reference-model state mirrors the corresponding RTL state/registers:
  //   model_gpio    - output data register that drives o_gpio
  //   model_q       - first input synchronizer stage (q_gpio)
  //   model_qq      - second synchronizer stage/readable INPUT register
  //   model_last    - previous synchronized input used for edge detection
  //   model_changed - sticky CHANGED bits (change-set, software W1C)
  //   model_mask    - interrupt mask/enable register
  //   model_int     - registered value that drives o_int
  //   in_reset      - scoreboard-side reset history, not a DUT register
  bit [AXI4L_DATA_WIDTH-1:0] model_gpio;
  bit [GPIO_NIN-1:0]         model_q;
  bit [GPIO_NIN-1:0]         model_qq;
  bit [GPIO_NIN-1:0]         model_last;
  bit [GPIO_NIN-1:0]         model_changed;
  bit [GPIO_NIN-1:0]         model_mask;
  bit                        model_int;
  bit                        in_reset;

  // Interrupt-mask polarity switch.  The implemented RTL uses MASK=1 to enable
  // an interrupt source.  Keeping the polarity configurable lets tests also
  // characterize the opposite interpretation found in an ambiguous spec note.
  bit mask_one_enable = 1'b1;

  int unsigned write_checks;
  int unsigned read_checks;
  int unsigned response_checks;
  int unsigned gpio_checks;
  int unsigned gpio_event_checks;
  int unsigned interrupt_checks;
  int unsigned error_count;

  function new(string name = "axi4l_gpio_scoreboard",
               uvm_component parent = null);
    super.new(name, parent);
    axi_req_imp = new("axi_req_imp", this);
    axi_rsp_imp = new("axi_rsp_imp", this);
    gpio_imp    = new("gpio_imp", this);
    clear_all_state();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(bit)::get(this, "", "mask_one_enable",
                                   mask_one_enable));
  endfunction

  function void clear_model_state();
    // Reset only architectural model state.  Protocol/event queues are cleared
    // separately because reset_at_cycle() must first account for callback order.
    model_gpio = '0;
    model_gpio[GPIO_NOUT-1:0] = GPIO_DEFAULT_OUTPUT;
    model_q       = '0;
    model_qq      = '0;
    model_last    = '0;
    model_changed = '0;
    model_mask    = '0;
    model_int     = 1'b0;
    in_reset      = 1'b1;
  endfunction

  function void clear_all_state();
    // Full scoreboard initialization: architectural state plus every queued
    // expected/actual item and the deferred GPIO observation.
    clear_model_state();
    request_events.delete();
    expected_write_responses.delete();
    expected_read_responses.delete();
    pending_write_responses.delete();
    pending_read_responses.delete();
    expected_gpio_events.delete();
    delayed_gpio_sample      = null;
    have_delayed_gpio_sample = 1'b0;
  endfunction

  function automatic bit [GPIO_NIN-1:0] active_interrupt_bits();
    // Return the per-source active vector.  Reduction to the scalar registered
    // o_int is deliberately performed later when computing next_int.
    if (mask_one_enable)
      return model_mask & model_changed;
    return ~model_mask & model_changed;
  endfunction

  function automatic bit [AXI4L_DATA_WIDTH-1:0] register_read_value(
    bit [AXI4L_ADDR_WIDTH-1:0] addr
  );
    // Decode a read from the *current* model state.  Aliased output-operation
    // addresses all read back the output register; unused upper bits stay zero.
    bit [AXI4L_DATA_WIDTH-1:0] value;
    value = '0;
    case (addr[AXI4L_ADDR_WIDTH-1:2])
      3'd0, 3'd1, 3'd2, 3'd3:
        value[GPIO_NOUT-1:0] = model_gpio[GPIO_NOUT-1:0];
      3'd4: value[GPIO_NIN-1:0] = model_qq;
      3'd5: value[GPIO_NIN-1:0] = model_changed;
      3'd6: value[GPIO_NIN-1:0] = model_mask;
      3'd7: value[GPIO_NIN-1:0] = active_interrupt_bits();
      default: begin end
    endcase
    return value;
  endfunction

  function automatic bit [AXI4L_DATA_WIDTH-1:0] apply_output_operation(
    bit [AXI4L_DATA_WIDTH-1:0] prior,
    axi4l_seq_item tr
  );
    // Model LOAD/SET/CLEAR/TOGGLE writes.  WSTRB gates each byte lane exactly
    // as in the RTL; bits above the implemented GPIO width are forced to zero.
    bit [AXI4L_DATA_WIDTH-1:0] result;
    result = prior;
    for (int lane = 0; lane < AXI4L_DATA_WIDTH/8; lane++) begin
      if (tr.strb[lane]) begin
        case (tr.addr[AXI4L_ADDR_WIDTH-1:2])
          3'd0: result[lane*8 +: 8] = tr.data[lane*8 +: 8];
          3'd1: result[lane*8 +: 8] = prior[lane*8 +: 8]
                                            | tr.data[lane*8 +: 8];
          3'd2: result[lane*8 +: 8] = prior[lane*8 +: 8]
                                            & ~tr.data[lane*8 +: 8];
          3'd3: result[lane*8 +: 8] = prior[lane*8 +: 8]
                                            ^ tr.data[lane*8 +: 8];
          default: begin end
        endcase
      end
    end
    if (GPIO_NOUT < AXI4L_DATA_WIDTH)
      result[AXI4L_DATA_WIDTH-1:GPIO_NOUT] = '0;
    return result;
  endfunction

  function automatic bit [GPIO_NIN-1:0] apply_mask_write(
    bit [GPIO_NIN-1:0] prior,
    axi4l_seq_item tr
  );
    // MASK is a normal byte-strobed register write (not SET/CLEAR/TOGGLE).
    // Padding permits the generic AXI byte-lane loop when GPIO_NIN is narrower.
    bit [AXI4L_DATA_WIDTH-1:0] padded;
    padded = '0;
    padded[GPIO_NIN-1:0] = prior;
    for (int lane = 0; lane < AXI4L_DATA_WIDTH/8; lane++)
      if (tr.strb[lane])
        padded[lane*8 +: 8] = tr.data[lane*8 +: 8];
    return padded[GPIO_NIN-1:0];
  endfunction

  function void report_error(string id, string message);
    error_count++;
    `uvm_error(id, message)
  endfunction

  function void write_axi_req(axi4l_seq_item tr);
    // Request monitor callback: clone because the producer may reuse its item.
    // Modeling is deferred until the GPIO sample with matching accept_cycle.
    axi4l_seq_item copy;
    if (!$cast(copy, tr.clone()))
      `uvm_fatal("SCB_CLONE", "Failed to clone AXI request event")
    request_events.push_back(copy);
  endfunction

  function void write_axi_rsp(axi4l_seq_item tr);
    // Response monitor callback: store the actual B or R response, then attempt
    // matching immediately in case its expected item is already available.
    axi4l_seq_item copy;
    if (!$cast(copy, tr.clone()))
      `uvm_fatal("SCB_CLONE", "Failed to clone AXI response event")
    if (tr.access == AXI4L_WRITE)
      pending_write_responses.push_back(copy);
    else
      pending_read_responses.push_back(copy);
    match_responses();
  endfunction

  function void write_gpio(gpio_observation sample);
    gpio_observation copy;

    // Defer each GPIO observation by one GPIO callback.  AXI and GPIO monitors
    // can publish same-cycle items in either simulator callback order; waiting
    // for the following sample guarantees that all requests for this cycle have
    // reached request_events before the sample is processed.  This is a
    // scoreboard scheduling device, NOT an extra cycle of DUT GPIO latency.
    if (have_delayed_gpio_sample)
      process_gpio_sample(delayed_gpio_sample);

    if (!$cast(copy, sample.clone()))
      `uvm_fatal("SCB_CLONE", "Failed to clone GPIO observation")
    delayed_gpio_sample      = copy;
    have_delayed_gpio_sample = 1'b1;
  endfunction

  function void reset_at_cycle(longint unsigned reset_cycle);
    // Reset invalidates all pre-reset predictions and observed responses.  The
    // architectural reset values are restored before normal modeling resumes.
    clear_model_state();

    // Preserve a request from the first post-reset cycle if that callback ran
    // before this delayed processing of the final reset sample.
    while ((request_events.size() != 0) &&
           (request_events[0].accept_cycle <= reset_cycle))
      void'(request_events.pop_front());

    expected_write_responses.delete();
    expected_read_responses.delete();
    pending_write_responses.delete();
    pending_read_responses.delete();
    expected_gpio_events.delete();
  endfunction

  function void compare_current_pins(gpio_observation sample);
    // Continuous state check: on every processed sample, compare the DUT pins
    // against the model state committed by earlier cycles.  This answers
    // "are the pins correct now?", independent of which write caused the state.
    gpio_checks++;
    if (sample.o_gpio !== model_gpio[GPIO_NOUT-1:0])
      report_error("SCB_GPIO",
        $sformatf("cycle %0d o_gpio expected 0x%0h, got 0x%0h",
                  sample.sample_cycle, model_gpio[GPIO_NOUT-1:0],
                  sample.o_gpio));

    interrupt_checks++;
    if (sample.o_int !== model_int)
      report_error("SCB_OINT",
        $sformatf("cycle %0d o_int expected %0b, got %0b",
                  sample.sample_cycle, model_int, sample.o_int));
  endfunction

  function void check_due_gpio_events(gpio_observation sample);
    // Transaction-timed side-effect check: prove that each particular output
    // write produced its predicted o_gpio value on its due cycle.  Unlike
    // compare_current_pins(), this preserves transaction ID and timing intent.
    gpio_expected_t event_item;
    while ((expected_gpio_events.size() != 0) &&
           (expected_gpio_events[0].due_cycle <= sample.sample_cycle)) begin
      event_item = expected_gpio_events.pop_front();
      gpio_event_checks++;
      if (event_item.due_cycle != sample.sample_cycle)
        report_error("SCB_GPIO_LATE",
          $sformatf("missed GPIO event tx=%0d due at cycle %0d",
                    event_item.transaction_id, event_item.due_cycle));
      else if (sample.o_gpio !== event_item.expected)
        report_error("SCB_GPIO_EVENT",
          $sformatf("cycle %0d tx=%0d expected o_gpio=0x%0h, got 0x%0h",
                    sample.sample_cycle, event_item.transaction_id,
                    event_item.expected, sample.o_gpio));
    end
  endfunction

  function void snapshot_read_expectation(axi4l_seq_item request);
    // Capture RDATA when the read request is accepted.  Later writes, input
    // synchronization, or CHANGED updates must not alter an already accepted
    // read's expectation while its response is still outstanding.
    axi4l_seq_item expected;
    if (!$cast(expected, request.clone()))
      `uvm_fatal("SCB_CLONE", "Failed to clone read expectation")
    expected.rdata = register_read_value(request.addr);
    expected.resp  = AXI_OKAY;
    expected_read_responses.push_back(expected);
  endfunction

  function void process_gpio_sample(gpio_observation sample);
    // This function is the model's clock step:
    //
    //   check current pins -> collect this-cycle requests -> snapshot reads
    //   -> calculate all next-state values -> commit next state -> match AXI
    //
    // All RHS model_* values represent pre-edge state until the final commit.
    // This mirrors RTL nonblocking assignments and makes read-before-write and
    // other same-edge behavior explicit rather than callback-order dependent.
    axi4l_seq_item cycle_reads[$];
    axi4l_seq_item cycle_writes[$];
    axi4l_seq_item request;
    axi4l_seq_item expected_response;
    gpio_expected_t gpio_event;
    bit [AXI4L_DATA_WIDTH-1:0] next_gpio;
    bit [GPIO_NIN-1:0] next_q;
    bit [GPIO_NIN-1:0] next_qq;
    bit [GPIO_NIN-1:0] next_last;
    bit [GPIO_NIN-1:0] next_changed;
    bit [GPIO_NIN-1:0] next_mask;
    bit [GPIO_NIN-1:0] detected_changes;
    bit next_int;

    if (sample.reset_n !== 1'b1) begin
      // A sampled active reset discards in-flight pre-reset expectations.
      reset_at_cycle(sample.sample_cycle);
      return;
    end

    if (in_reset)
      in_reset = 1'b0;

    compare_current_pins(sample);
    check_due_gpio_events(sample);

    // Consume only requests accepted on or before this sample.  A strictly
    // older request means the deferral/order contract was violated.
    while ((request_events.size() != 0) &&
           (request_events[0].accept_cycle <= sample.sample_cycle)) begin
      request = request_events.pop_front();
      if (request.accept_cycle < sample.sample_cycle)
        report_error("SCB_REQ_LATE",
          $sformatf("request tx=%0d was not modeled at acceptance cycle %0d",
                    request.transaction_id, request.accept_cycle));
      if (request.access == AXI4L_READ)
        cycle_reads.push_back(request);
      else
        cycle_writes.push_back(request);
    end

    // RTL captures read data from pre-edge state.  Reads are therefore
    // snapshotted before any same-cycle writes or sampled-input updates below.
    foreach (cycle_reads[i])
      snapshot_read_expectation(cycle_reads[i]);

    // Build next state without changing current state:
    //   i_gpio -> q -> qq -> last is the modeled CDC/synchronizer pipeline.
    // next_int is computed from the old MASK/CHANGED state, matching registered
    // o_int timing rather than a combinational view of updates on this edge.
    next_gpio    = model_gpio;
    next_q       = sample.i_gpio;
    next_qq      = model_q;
    next_last    = model_qq;
    next_changed = model_changed;
    next_mask    = model_mask;
    next_int     = |active_interrupt_bits();

    foreach (cycle_writes[i]) begin
      // Every accepted write predicts an OKAY B response.  Register side
      // effects are accumulated into next_* so multiple same-cycle operations
      // have a deterministic request order.
      request = cycle_writes[i];
      if (!$cast(expected_response, request.clone()))
        `uvm_fatal("SCB_CLONE", "Failed to clone write expectation")
      expected_response.resp = AXI_OKAY;
      expected_write_responses.push_back(expected_response);

      case (request.addr[AXI4L_ADDR_WIDTH-1:2])
        3'd0, 3'd1, 3'd2, 3'd3: begin
          next_gpio = apply_output_operation(next_gpio, request);
          write_checks++;
          // The model state commits below, so the updated pin is checked on the
          // next numbered GPIO observation.  This is DUT timing, distinct from
          // write_gpio()'s callback-order deferral.
          gpio_event.due_cycle      = sample.sample_cycle + 1;
          gpio_event.transaction_id = request.transaction_id;
          gpio_event.expected       = next_gpio[GPIO_NOUT-1:0];
          expected_gpio_events.push_back(gpio_event);
        end
        3'd5: begin
          for (int bit_index = 0; bit_index < GPIO_NIN; bit_index++)
            if (request.strb[bit_index/8] && request.data[bit_index])
              next_changed[bit_index] = 1'b0;
        end
        3'd6: next_mask = apply_mask_write(next_mask, request);
        default: begin end
      endcase
    end

    // Edge detection uses pre-edge last/qq.  OR after software's W1C update so
    // a hardware-detected change wins over a clear of that bit on the same edge.
    detected_changes = model_last ^ model_qq;
    next_changed |= detected_changes;

    // Atomic commit: only now does calculated next state become current state
    // for the following GPIO sample and future accepted-read snapshots.
    model_gpio    = next_gpio;
    model_q       = next_q;
    model_qq      = next_qq;
    model_last    = next_last;
    model_changed = next_changed;
    model_mask    = next_mask;
    model_int     = next_int;

    match_responses();
  endfunction

  function void match_responses();
    // Pair expected and actual responses in FIFO order.  Transaction IDs prove
    // ordering; BRESP/RRESP prove protocol status; read data is additionally
    // checked against the acceptance-time snapshot.  Either stream may arrive
    // first because unmatched items remain queued.
    axi4l_seq_item expected;
    axi4l_seq_item actual;

    while ((expected_write_responses.size() != 0) &&
           (pending_write_responses.size() != 0)) begin
      expected = expected_write_responses.pop_front();
      actual   = pending_write_responses.pop_front();
      response_checks++;
      if (actual.transaction_id != expected.transaction_id)
        report_error("SCB_B_ORDER",
          $sformatf("write response tx=%0d, expected tx=%0d",
                    actual.transaction_id, expected.transaction_id));
      if (actual.resp !== AXI_OKAY)
        report_error("SCB_BRESP",
          $sformatf("write tx=%0d returned %02b, expected OKAY",
                    actual.transaction_id, actual.resp));
    end

    while ((expected_read_responses.size() != 0) &&
           (pending_read_responses.size() != 0)) begin
      expected = expected_read_responses.pop_front();
      actual   = pending_read_responses.pop_front();
      response_checks++;
      read_checks++;
      if (actual.transaction_id != expected.transaction_id)
        report_error("SCB_R_ORDER",
          $sformatf("read response tx=%0d, expected tx=%0d",
                    actual.transaction_id, expected.transaction_id));
      if (actual.resp !== AXI_OKAY)
        report_error("SCB_RRESP",
          $sformatf("read tx=%0d returned %02b, expected OKAY",
                    actual.transaction_id, actual.resp));
      if (actual.rdata !== expected.rdata)
        report_error("SCB_RDATA",
          $sformatf("read tx=%0d addr=0x%02h expected 0x%08h, got 0x%08h",
                    actual.transaction_id, actual.addr,
                    expected.rdata, actual.rdata));
    end
  endfunction

  function void check_phase(uvm_phase phase);
    // Flush the final deferred sample, make one last matching attempt, then
    // require every queue to be empty.  Non-empty queues mean an accepted
    // request, predicted response/side effect, or actual response was never
    // paired before end-of-test—even if all comparisons performed so far passed.
    super.check_phase(phase);
    if (have_delayed_gpio_sample) begin
      process_gpio_sample(delayed_gpio_sample);
      delayed_gpio_sample      = null;
      have_delayed_gpio_sample = 1'b0;
    end
    match_responses();

    if (request_events.size() != 0)
      report_error("SCB_REQ_PENDING",
        $sformatf("%0d accepted request event(s) were not modeled",
                  request_events.size()));
    if (expected_write_responses.size() != 0 ||
        pending_write_responses.size() != 0)
      report_error("SCB_B_PENDING",
        $sformatf("write response queues not empty: expected=%0d actual=%0d",
                  expected_write_responses.size(),
                  pending_write_responses.size()));
    if (expected_read_responses.size() != 0 ||
        pending_read_responses.size() != 0)
      report_error("SCB_R_PENDING",
        $sformatf("read response queues not empty: expected=%0d actual=%0d",
                  expected_read_responses.size(), pending_read_responses.size()));
    if (expected_gpio_events.size() != 0)
      report_error("SCB_GPIO_PENDING",
        $sformatf("%0d expected GPIO event(s) not observed before test end",
                  expected_gpio_events.size()));
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (error_count == 0) begin
      `uvm_info("SCB_PASS",
        $sformatf("V2 scoreboard PASS: output_writes=%0d reads=%0d responses=%0d pin_cycles=%0d gpio_events=%0d int_cycles=%0d",
                  write_checks, read_checks, response_checks, gpio_checks,
                  gpio_event_checks, interrupt_checks), UVM_NONE)
    end else begin
      `uvm_error("SCB_FAIL",
        $sformatf("V2 scoreboard FAIL: errors=%0d output_writes=%0d reads=%0d responses=%0d",
                  error_count, write_checks, read_checks, response_checks))
    end
  endfunction
endclass
