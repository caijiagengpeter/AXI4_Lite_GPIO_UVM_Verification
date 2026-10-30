class gpio_monitor extends uvm_monitor;
  `uvm_component_utils(gpio_monitor)

  virtual gpio_if #(GPIO_NIN, GPIO_NOUT) vif;
  uvm_analysis_port #(gpio_observation) ap;

  logic [GPIO_NIN-1:0] last_i_gpio;
  bit                  have_last_i_gpio;
  int unsigned         sample_count;
  int unsigned         observed_level_count;
  longint unsigned     sample_cycle;

  function new(string name = "gpio_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual gpio_if #(GPIO_NIN, GPIO_NOUT))::get(
          this, "", "gpio_vif", vif))
      `uvm_fatal("NOVIF", "gpio_monitor did not receive gpio_vif")
  endfunction

  task run_phase(uvm_phase phase);
    gpio_observation observation;

    // Publish every clock sample, including reset.  This is intentionally
    // simple and guarantees that later CDC/reference-model logic cannot miss
    // a short but valid pin transition.  Consumers decide which samples matter.
    forever begin
      @(vif.mon_cb);
      observation = gpio_observation::type_id::create("observation");
      sample_cycle++;
      observation.reset_n = vif.mon_cb.ARESETN;
      observation.i_gpio  = vif.mon_cb.i_gpio;
      observation.o_gpio  = vif.mon_cb.o_gpio;
      observation.o_int   = vif.mon_cb.o_int;
      observation.sample_cycle = sample_cycle;
      sample_count++;
      ap.write(observation);

      // This message records observations only; it does not calculate an
      // expected value or implement any DUT register semantics.
      if (observation.reset_n === 1'b1) begin
        if (!have_last_i_gpio ||
            (observation.i_gpio !== last_i_gpio)) begin
          observed_level_count++;
          `uvm_info("GPIO_MON",
                    $sformatf("observed i_gpio=%05b o_gpio=0x%0h o_int=%0b",
                              observation.i_gpio, observation.o_gpio,
                              observation.o_int),
                    UVM_MEDIUM)
        end
        last_i_gpio      = observation.i_gpio;
        have_last_i_gpio = 1'b1;
      end else begin
        have_last_i_gpio = 1'b0;
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("GPIO_MON_SUMMARY",
              $sformatf("samples=%0d observed_input_levels=%0d",
                        sample_count, observed_level_count),
              UVM_NONE)
  endfunction
endclass
