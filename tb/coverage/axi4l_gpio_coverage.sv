class axi4l_gpio_coverage extends uvm_component;
  `uvm_component_utils(axi4l_gpio_coverage)

  uvm_analysis_imp_cov_axi_req #(axi4l_seq_item,
                                 axi4l_gpio_coverage) axi_req_imp;
  uvm_analysis_imp_cov_gpio #(gpio_observation,
                              axi4l_gpio_coverage) gpio_imp;

  logic [GPIO_NIN-1:0]  previous_i_gpio;
  logic [GPIO_NOUT-1:0] previous_o_gpio;
  bit                   have_gpio_history;
  int unsigned          axi_request_samples;
  int unsigned          gpio_samples;

  // Transaction-shape coverage is sampled only from accepted monitor
  // requests.  It does not predict responses or reproduce register behavior.
  covergroup axi_request_cg with function sample(
    bit is_write,
    bit [2:0] word_addr,
    bit [AXI4L_DATA_WIDTH/8-1:0] strb,
    int aw_w_order
  );
    option.per_instance = 1;
    cp_access: coverpoint is_write {
      bins read  = {0};
      bins write = {1};
    }
    cp_addr: coverpoint word_addr {
      bins registers[] = {[0:7]};
    }
    cp_strb: coverpoint strb iff (is_write) {
      bins none       = {'0};
      bins full       = {'1};
      bins single[]   = {4'b0001, 4'b0010, 4'b0100, 4'b1000};
      bins multi      = default;
    }
    cp_aw_w_order: coverpoint aw_w_order iff (is_write) {
      bins same_cycle = {0};
      bins aw_first   = {1};
      bins w_first    = {2};
    }
    access_x_addr: cross cp_access, cp_addr;
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
      bins multi  = {[2:GPIO_NIN]};
    }
    cp_output_changed: coverpoint output_changed iff (reset_n);
    cp_int: coverpoint interrupt_value iff (reset_n);
    edge_x_int: cross cp_rise, cp_fall, cp_int iff (reset_n);
  endgroup

  function new(string name = "axi4l_gpio_coverage",
               uvm_component parent = null);
    super.new(name, parent);
    axi_req_imp = new("axi_req_imp", this);
    gpio_imp    = new("gpio_imp", this);
    axi_request_cg     = new;
    gpio_observation_cg = new;
  endfunction

  function automatic int aw_w_order(axi4l_seq_item tr);
    if (tr.aw_cycle == tr.w_cycle)
      return 0;
    if (tr.aw_cycle < tr.w_cycle)
      return 1;
    return 2;
  endfunction

  function void write_cov_axi_req(axi4l_seq_item tr);
    axi_request_samples++;
    axi_request_cg.sample(tr.access == AXI4L_WRITE,
                          tr.addr[AXI4L_ADDR_WIDTH-1:2], tr.strb,
                          aw_w_order(tr));
  endfunction

  function void write_cov_gpio(gpio_observation sample);
    bit [GPIO_NIN-1:0] changed;
    bit any_rise;
    bit any_fall;
    bit output_changed;

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

    gpio_observation_cg.sample(sample.reset_n === 1'b1,
                               any_rise, any_fall, $countones(changed),
                               output_changed, sample.o_int);

    if (sample.reset_n === 1'b1) begin
      previous_i_gpio  = sample.i_gpio;
      previous_o_gpio  = sample.o_gpio;
      have_gpio_history = 1'b1;
    end else begin
      have_gpio_history = 1'b0;
    end
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("COV_SUMMARY",
      $sformatf("coverage samples: AXI requests=%0d GPIO observations=%0d",
                axi_request_samples, gpio_samples), UVM_NONE)
  endfunction
endclass
