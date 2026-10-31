class axi4l_gpio_coverage extends uvm_component;
  `uvm_component_utils(axi4l_gpio_coverage)

  uvm_analysis_imp_cov_axi_req #(axi4l_seq_item,
                                 axi4l_gpio_coverage) axi_req_imp;
  uvm_analysis_imp_cov_axi_rsp #(axi4l_seq_item,
                                 axi4l_gpio_coverage) axi_rsp_imp;
  uvm_analysis_imp_cov_bus #(axi4l_bus_observation,
                             axi4l_gpio_coverage) bus_imp;
  uvm_analysis_imp_cov_timing #(axi4l_timing_observation,
                                axi4l_gpio_coverage) timing_imp;
  uvm_analysis_imp_cov_gpio #(gpio_observation,
                              axi4l_gpio_coverage) gpio_imp;

  logic [GPIO_NIN-1:0]  previous_i_gpio;
  logic [GPIO_NOUT-1:0] previous_o_gpio;
  logic                 previous_o_int;
  bit                   have_gpio_history;
  bit [GPIO_NIN-1:0]    coverage_q;
  bit [GPIO_NIN-1:0]    coverage_qq;
  bit [GPIO_NIN-1:0]    coverage_last;
  bit [GPIO_NIN-1:0]    coverage_mask;
  bit [GPIO_NIN-1:0]    hw_change_by_cycle[longint unsigned];
  bit [GPIO_NIN-1:0]    w1c_by_cycle[longint unsigned];
  bit                   w1c_data_by_cycle[longint unsigned];
  bit                   w1c_strobe_by_cycle[longint unsigned];
  bit                   gpio_cycle_known[longint unsigned];
  bit [31:0]            output_model;
  int unsigned          axi_request_samples;
  int unsigned          axi_response_samples;
  int unsigned          bus_samples;
  int unsigned          timing_samples;
  int unsigned          gpio_samples;
  longint unsigned      last_write_commit_cycle;
  longint unsigned      last_read_snapshot_cycle;
  bit                   have_write_commit_cycle;
  bit                   have_read_snapshot_cycle;

  // Request shape is sampled only after the passive monitor has observed both
  // AW and W handshakes (or an AR handshake).  Every 32-bit WSTRB value is an
  // explicit bin: unlike a default bin, none of the ten other-partial values
  // can be excluded from the denominator by the coverage tool.
  covergroup axi_request_cg with function sample(
    bit is_write,
    bit [2:0] word_addr,
    bit [AXI4L_DATA_WIDTH/8-1:0] strb,
    int aw_w_relation
  );
    option.per_instance = 1;
    cp_access: coverpoint is_write {
      bins read  = {0};
      bins write = {1};
    }
    cp_addr: coverpoint word_addr {
      bins registers[] = {[0:7]};
    }
    cp_strb_pattern: coverpoint strb iff (is_write) {
      bins patterns[] = {[4'b0000:4'b1111]};
    }
    cp_strb_class: coverpoint strb iff (is_write) {
      bins zero = {4'b0000};
      bins lane0 = {4'b0001};
      bins lane1 = {4'b0010};
      bins lane2 = {4'b0100};
      bins lane3 = {4'b1000};
      bins other_partial[] = {4'b0011, 4'b0101, 4'b0110, 4'b0111,
                              4'b1001, 4'b1010, 4'b1011, 4'b1100,
                              4'b1101, 4'b1110};
      bins full = {4'b1111};
    }
    cp_legal_write_reg: coverpoint word_addr iff (is_write &&
      (word_addr inside {3'd0, 3'd1, 3'd2, 3'd3, 3'd5, 3'd6})) {
      bins load = {0};
      bins set = {1};
      bins clear = {2};
      bins toggle = {3};
      bins changed_w1c = {5};
      bins mask = {6};
    }
    cp_aw_w_relation: coverpoint aw_w_relation iff (is_write) {
      bins simultaneous = {0};
      bins aw_first_gap1 = {1};
      bins aw_first_gap2_3 = {2};
      bins aw_first_gap4_7 = {3};
      bins aw_first_gap8_plus = {4};
      bins w_first_gap1 = {5};
      bins w_first_gap2_3 = {6};
      bins w_first_gap4_7 = {7};
      bins w_first_gap8_plus = {8};
    }
    access_x_addr: cross cp_access, cp_addr;
    legal_reg_x_strb: cross cp_legal_write_reg, cp_strb_pattern;
  endgroup

  // GPIO coverage characterizes observed pins only.  The one-sample history
  // derives edge categories, but it contains no expected values or checking.
  covergroup gpio_observation_cg with function sample(
    bit reset_n,
    bit any_rise,
    bit any_fall,
    int changed_bits,
    bit output_changed,
    bit interrupt_value
  );
    option.per_instance = 1;
    cp_reset: coverpoint reset_n;
    cp_rise: coverpoint any_rise iff (reset_n);
    cp_fall: coverpoint any_fall iff (reset_n);
    cp_changed_bits: coverpoint changed_bits iff (reset_n) {
      bins none   = {0};
      bins single = {1};
      // A fixed upper bound keeps the covergroup legal for the NIN=0 build;
      // sampled values can never exceed the elaborated input width.
      bins multi  = {[2:32]};
    }
    cp_output_changed: coverpoint output_changed iff (reset_n);
    cp_int: coverpoint interrupt_value iff (reset_n);
    edge_x_int: cross cp_rise, cp_fall, cp_int iff (reset_n);
  endgroup

  covergroup axi_response_cg with function sample(
    bit is_write, int stall_cycles, int relation_backpressure,
    int response_latency
  );
    option.per_instance = 1;
    cp_access: coverpoint is_write { bins read = {0}; bins write = {1}; }
    cp_stall: coverpoint stall_cycles {
      bins none = {0}; bins one = {1}; bins short = {[2:3]};
      bins moderate = {[4:7]}; bins extended = {[8:$]};
    }
    cp_latency: coverpoint response_latency {
      bins immediate = {0}; bins one = {1}; bins short = {[2:3]};
      bins moderate = {[4:7]}; bins extended = {[8:$]};
    }
    cp_write_relation_x_bp: coverpoint relation_backpressure iff (is_write) {
      bins simultaneous_no_bp = {0}; bins simultaneous_bp = {1};
      bins aw_first_no_bp = {2}; bins aw_first_bp = {3};
      bins w_first_no_bp = {4}; bins w_first_bp = {5};
    }
    access_x_stall: cross cp_access, cp_stall;
  endgroup

  covergroup timing_event_cg with function sample(
    bit is_write_commit, bit [2:0] word_addr, int latency
  );
    option.per_instance = 1;
    cp_kind: coverpoint is_write_commit {
      bins read_snapshot = {0}; bins write_commit = {1};
    }
    cp_addr: coverpoint word_addr { bins registers[] = {[0:7]}; }
    cp_latency: coverpoint latency {
      bins same_cycle = {0}; bins one = {1}; bins short = {[2:3]};
      bins moderate = {[4:7]}; bins extended = {[8:$]};
    }
    kind_x_latency: cross cp_kind, cp_latency;
  endgroup

  covergroup same_edge_rw_cg with function sample(bit observed);
    option.per_instance = 1;
    cp_observed: coverpoint observed { bins read_old_write_new = {1}; }
  endgroup

  covergroup bus_behavior_cg with function sample(
    bit aw_stall, bit w_stall, bit b_stall, bit r_stall,
    int write_outstanding, int read_outstanding
  );
    option.per_instance = 1;
    cp_aw_stall: coverpoint aw_stall { bins observed = {1}; }
    cp_w_stall: coverpoint w_stall { bins observed = {1}; }
    cp_b_stall: coverpoint b_stall { bins observed = {1}; }
    cp_r_stall: coverpoint r_stall { bins observed = {1}; }
    cp_write_outstanding: coverpoint write_outstanding {
      bins idle = {0}; bins one = {1}; bins two = {2};
    }
    cp_read_outstanding: coverpoint read_outstanding {
      bins idle = {0}; bins one = {1}; bins two = {2};
    }
  endgroup

  covergroup reset_context_cg with function sample(int reset_context);
    option.per_instance = 1;
    cp_context: coverpoint reset_context {
      bins idle = {0}; bins aw_only = {1}; bins w_only = {2};
      bins accepted_write_pending = {3}; bins accepted_read_pending = {4};
      bins b_stalled = {5}; bins r_stalled = {6};
    }
  endgroup

  covergroup w1c_collision_cg with function sample(bit collision);
    option.per_instance = 1;
    cp_collision: coverpoint collision { bins hw_change_wins = {1}; }
  endgroup

  covergroup w1c_matrix_cg with function sample(
    bit data_one, bit strobe_on, bit hardware_change, bit change_won
  );
    option.per_instance = 1;
    cp_data: coverpoint data_one { bins zero = {0}; bins one = {1}; }
    cp_strobe: coverpoint strobe_on { bins off = {0}; bins on = {1}; }
    cp_hardware: coverpoint hardware_change {
      bins stable = {0}; bins changing = {1};
    }
    cp_change_won: coverpoint change_won { bins observed = {1}; }
    data_x_strobe_x_hardware: cross cp_data, cp_strobe, cp_hardware;
  endgroup

  covergroup mask_irq_cg with function sample(
    bit any_mask_enabled, bit interrupt_value, int interrupt_event
  );
    option.per_instance = 1;
    cp_mask: coverpoint any_mask_enabled {
      bins disabled = {0}; bins enabled = {1};
    }
    cp_int: coverpoint interrupt_value {
      bins inactive = {0}; bins active = {1};
    }
    cp_int_event: coverpoint interrupt_event {
      bins stable_low = {0}; bins assert_event = {1};
      bins stable_high = {2}; bins deassert_event = {3};
    }
    mask_x_int: cross cp_mask, cp_int;
  endgroup

  covergroup output_operation_cg with function sample(
    int operation, bit changed, bit zero_strobe
  );
    option.per_instance = 1;
    cp_operation: coverpoint operation {
      bins load = {0}; bins set = {1}; bins clear = {2}; bins toggle = {3};
    }
    cp_changed: coverpoint changed {
      bins no_change = {0}; bins change = {1};
    }
    cp_zero_strobe: coverpoint zero_strobe {
      bins active = {0}; bins preserve = {1};
    }
    operation_x_changed: cross cp_operation, cp_changed;
    operation_x_zero_strobe: cross cp_operation, cp_zero_strobe;
  endgroup

  function new(string name = "axi4l_gpio_coverage",
               uvm_component parent = null);
    super.new(name, parent);
    axi_req_imp = new("axi_req_imp", this);
    axi_rsp_imp = new("axi_rsp_imp", this);
    bus_imp = new("bus_imp", this);
    timing_imp = new("timing_imp", this);
    gpio_imp    = new("gpio_imp", this);
    axi_request_cg     = new;
    axi_response_cg = new;
    timing_event_cg = new;
    same_edge_rw_cg = new;
    bus_behavior_cg = new;
    reset_context_cg = new;
    w1c_collision_cg = new;
    w1c_matrix_cg = new;
    mask_irq_cg = new;
    output_operation_cg = new;
    gpio_observation_cg = new;
    output_model = '0;
    output_model[GPIO_NOUT-1:0] = GPIO_DEFAULT_OUTPUT;
  endfunction

  function automatic int aw_w_order(axi4l_seq_item tr);
    if (tr.aw_cycle == tr.w_cycle)
      return 0;
    if (tr.aw_cycle < tr.w_cycle)
      return 1;
    return 2;
  endfunction

  function automatic int aw_w_relation(axi4l_seq_item tr);
    int unsigned gap;
    if (tr.aw_cycle == tr.w_cycle)
      return 0;
    gap = (tr.aw_cycle > tr.w_cycle) ? tr.aw_cycle - tr.w_cycle
                                     : tr.w_cycle - tr.aw_cycle;
    if (tr.aw_cycle < tr.w_cycle) begin
      if (gap == 1) return 1;
      if (gap <= 3) return 2;
      if (gap <= 7) return 3;
      return 4;
    end
    if (gap == 1) return 5;
    if (gap <= 3) return 6;
    if (gap <= 7) return 7;
    return 8;
  endfunction

  function automatic int relation_backpressure(axi4l_seq_item tr);
    int relation;
    relation = aw_w_order(tr);
    return (relation * 2) + (tr.response_stall_cycles != 0);
  endfunction

  function void write_cov_axi_req(axi4l_seq_item tr);
    axi_request_samples++;
    axi_request_cg.sample(tr.access == AXI4L_WRITE,
                          tr.addr[AXI4L_ADDR_WIDTH-1:2], tr.strb,
                          aw_w_relation(tr));
  endfunction

  function void write_cov_axi_rsp(axi4l_seq_item tr);
    int latency;
    axi_response_samples++;
    latency = (tr.response_cycle >= tr.accept_cycle)
            ? tr.response_cycle - tr.accept_cycle : 0;
    axi_response_cg.sample(tr.access == AXI4L_WRITE,
                           tr.response_stall_cycles,
                           relation_backpressure(tr), latency);
  endfunction

  function void write_cov_bus(axi4l_bus_observation observation);
    bus_samples++;
    if (observation.reset_n)
      bus_behavior_cg.sample(observation.aw_stall, observation.w_stall,
                             observation.b_stall, observation.r_stall,
                             observation.write_outstanding,
                             observation.read_outstanding);
    if (observation.reset_enter) begin
      reset_context_cg.sample(observation.reset_context);
      output_model = '0;
      output_model[GPIO_NOUT-1:0] = GPIO_DEFAULT_OUTPUT;
    end
  endfunction

  function automatic bit [2:0] coverage_word_addr(axi4l_seq_item request);
    if (GPIO_NIN == 0)
      return {1'b0, request.addr[3:2]};
    return request.addr[AXI4L_ADDR_WIDTH-1:2];
  endfunction

  function automatic bit [31:0] coverage_output_after_write(
    bit [31:0] prior, axi4l_seq_item request
  );
    bit [31:0] result;
    bit [2:0] operation;
    result = prior;
    operation = coverage_word_addr(request);
    for (int lane = 0; lane < 4; lane++)
      if (request.strb[lane]) begin
        case (operation)
          3'd0: result[lane*8 +: 8] = request.data[lane*8 +: 8];
          3'd1: result[lane*8 +: 8] |= request.data[lane*8 +: 8];
          3'd2: result[lane*8 +: 8] &= ~request.data[lane*8 +: 8];
          3'd3: result[lane*8 +: 8] ^= request.data[lane*8 +: 8];
          default: begin end
        endcase
      end
    for (int bit_index = GPIO_NOUT; bit_index < 32; bit_index++)
      result[bit_index] = 1'b0;
    return result;
  endfunction

  function void try_sample_w1c_collision(longint unsigned cycle);
    if (gpio_cycle_known.exists(cycle) && w1c_by_cycle.exists(cycle)) begin
      w1c_collision_cg.sample(|(hw_change_by_cycle[cycle] &
                                w1c_by_cycle[cycle]));
      w1c_matrix_cg.sample(w1c_data_by_cycle[cycle],
                           w1c_strobe_by_cycle[cycle],
                           |hw_change_by_cycle[cycle],
                           |(hw_change_by_cycle[cycle] &
                             w1c_by_cycle[cycle]));
      gpio_cycle_known.delete(cycle);
      hw_change_by_cycle.delete(cycle);
      w1c_by_cycle.delete(cycle);
      w1c_data_by_cycle.delete(cycle);
      w1c_strobe_by_cycle.delete(cycle);
    end
  endfunction

  function void write_cov_timing(axi4l_timing_observation observation);
    int latency;
    bit [GPIO_NIN-1:0] clear_mask;
    bit any_data;
    bit any_strobe;
    bit [31:0] next_output;
    bit [2:0] word_addr;
    timing_samples++;
    latency = (observation.event_cycle >= observation.request.accept_cycle)
            ? observation.event_cycle - observation.request.accept_cycle : 0;
    if (observation.whitebox_exact)
      timing_event_cg.sample(observation.is_write_commit,
        observation.request.addr[AXI4L_ADDR_WIDTH-1:2], latency);

    if (observation.is_write_commit) begin
      word_addr = coverage_word_addr(observation.request);
      if (word_addr <= 3) begin
        next_output = coverage_output_after_write(output_model,
                                                  observation.request);
        output_operation_cg.sample(word_addr,
                                   next_output != output_model,
                                   observation.request.strb == '0);
        output_model = next_output;
      end
      last_write_commit_cycle = observation.event_cycle;
      have_write_commit_cycle = 1'b1;
      if (have_read_snapshot_cycle &&
          (last_read_snapshot_cycle == observation.event_cycle))
        same_edge_rw_cg.sample(1'b1);
      if (observation.request.addr[AXI4L_ADDR_WIDTH-1:2] == 3'd5) begin
        clear_mask = '0;
        any_data = 1'b0;
        any_strobe = 1'b0;
        for (int bit_index = 0; bit_index < GPIO_NIN; bit_index++)
          begin
            if (observation.request.data[bit_index])
              any_data = 1'b1;
            if (observation.request.strb[bit_index/8])
              any_strobe = 1'b1;
            if (observation.request.strb[bit_index/8] &&
                observation.request.data[bit_index])
              clear_mask[bit_index] = 1'b1;
          end
        w1c_by_cycle[observation.event_cycle] = clear_mask;
        w1c_data_by_cycle[observation.event_cycle] = any_data;
        w1c_strobe_by_cycle[observation.event_cycle] = any_strobe;
        try_sample_w1c_collision(observation.event_cycle);
      end
      if (observation.request.addr[AXI4L_ADDR_WIDTH-1:2] == 3'd6)
        for (int bit_index = 0; bit_index < GPIO_NIN; bit_index++)
          if (observation.request.strb[bit_index/8])
            coverage_mask[bit_index] = observation.request.data[bit_index];
    end else begin
      last_read_snapshot_cycle = observation.event_cycle;
      have_read_snapshot_cycle = 1'b1;
      if (have_write_commit_cycle &&
          (last_write_commit_cycle == observation.event_cycle))
        same_edge_rw_cg.sample(1'b1);
    end
  endfunction

  function void write_cov_gpio(gpio_observation sample);
    bit [GPIO_NIN-1:0] changed;
    bit any_rise;
    bit any_fall;
    bit output_changed;
    bit [GPIO_NIN-1:0] detected_changes;
    int interrupt_event;

    gpio_samples++;
    changed        = '0;
    any_rise       = 1'b0;
    any_fall       = 1'b0;
    output_changed = 1'b0;

    if (sample.reset_n === 1'b1 && have_gpio_history) begin
      changed        = sample.i_gpio ^ previous_i_gpio;
      any_rise       = |(sample.i_gpio & ~previous_i_gpio);
      any_fall       = |(~sample.i_gpio & previous_i_gpio);
      output_changed = sample.o_gpio != previous_o_gpio;
    end

    if (sample.reset_n === 1'b1) begin
      detected_changes = coverage_last ^ coverage_qq;
      hw_change_by_cycle[sample.sample_cycle] = detected_changes;
      gpio_cycle_known[sample.sample_cycle] = 1'b1;
      try_sample_w1c_collision(sample.sample_cycle);
      coverage_last = coverage_qq;
      coverage_qq = coverage_q;
      coverage_q = sample.i_gpio;
      interrupt_event = (!have_gpio_history || !previous_o_int) && sample.o_int ? 1 :
                        (have_gpio_history && previous_o_int && !sample.o_int) ? 3 :
                        sample.o_int ? 2 : 0;
      mask_irq_cg.sample(|coverage_mask, sample.o_int, interrupt_event);
    end

    gpio_observation_cg.sample(sample.reset_n === 1'b1,
                               any_rise, any_fall, $countones(changed),
                               output_changed, sample.o_int);

    if (sample.reset_n === 1'b1) begin
      previous_i_gpio  = sample.i_gpio;
      previous_o_gpio  = sample.o_gpio;
      previous_o_int   = sample.o_int;
      have_gpio_history = 1'b1;
    end else begin
      have_gpio_history = 1'b0;
      coverage_q = '0;
      coverage_qq = '0;
      coverage_last = '0;
      coverage_mask = '0;
      gpio_cycle_known.delete();
      hw_change_by_cycle.delete();
      w1c_by_cycle.delete();
      w1c_data_by_cycle.delete();
      w1c_strobe_by_cycle.delete();
    end
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("COV_SUMMARY",
      $sformatf("coverage samples: AXI req/rsp=%0d/%0d bus=%0d timing=%0d GPIO=%0d",
                axi_request_samples, axi_response_samples, bus_samples,
                timing_samples, gpio_samples), UVM_NONE)
  endfunction
endclass
