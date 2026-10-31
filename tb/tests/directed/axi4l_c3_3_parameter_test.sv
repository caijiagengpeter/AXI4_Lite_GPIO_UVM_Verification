class axi4l_c3_3_parameter_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_c3_3_parameter_test)

  function new(string name = "axi4l_c3_3_parameter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    bit [31:0] all_outputs;
    bit [31:0] alternating;

    phase.raise_objection(this);
    all_outputs = '1;
    alternating = 32'ha5a5_5a5a;
    gpio_level('0, 4);

    // Operation x change/no-change and byte preservation.  Every access is
    // checked through the normal timing monitor, independent scoreboard, and
    // protocol assertions for the elaborated parameter set.
    axi_write(5'h00, alternating, 4'b1111);
    axi_write(5'h00, alternating, 4'b1111); // LOAD no change
    axi_write(5'h04, 32'h0000_0000, 4'b1111); // SET no change
    axi_write(5'h04, all_outputs, 4'b1111); // SET changes
    axi_write(5'h08, 32'h0000_0000, 4'b1111); // CLEAR no change
    axi_write(5'h08, 32'h00ff_00ff, 4'b0101); // CLEAR changes
    axi_write(5'h0c, 32'h0000_0000, 4'b1111); // TOGGLE no change
    axi_write(5'h0c, 32'hff00_ff00, 4'b1010); // TOGGLE changes
    axi_write(5'h00, 32'hdead_beef, 4'b0000); // explicit preservation
    axi_read(5'h00);

    // The RTL ignores AXI byte offsets.  Prove the three unaligned aliases
    // instead of assuming they are errors.
    axi_write(5'h01, 32'h1122_3344, 4'b1111);
    axi_read(5'h02);
    axi_read(5'h03);

    if (GPIO_NIN == 0) begin
      // With no inputs, upper words alias the four output operations.
      axi_write(5'h10, 32'h55aa_33cc, 4'b1111);
      axi_read(5'h10);
      axi_write(5'h14, 32'h0000_0003, 4'b0001);
      axi_read(5'h04);
      axi_write(5'h18, 32'h0000_0001, 4'b0001);
      axi_read(5'h08);
      axi_write(5'h1c, 32'h0000_000f, 4'b0001);
      axi_read(5'h0c);
    end else begin
      // Exercise synchronizer, sticky, W1C and implemented MASK=1-enable
      // behavior for every positive-NIN configuration.
      axi_write(5'h18, 32'hffff_ffff, 4'b1111);
      gpio_level('1, 6);
      axi_read(5'h10);
      axi_read(5'h14);
      axi_read(5'h1c);
      axi_write(5'h14, 32'hffff_ffff, 4'b1111);
      gpio_level('0, 6);
      axi_read(5'h14);
      axi_read(5'h1c);
    end

    repeat (5) @(env.axi_agent.driver.vif.mon_cb);
    `uvm_info("C3_3_PARAMETER_PASS",
      $sformatf("checked NIN=%0d NOUT=%0d skid=%0d lowpower=%0d default=0x%0h",
        GPIO_NIN, GPIO_NOUT, GPIO_OPT_SKIDBUFFER, GPIO_OPT_LOWPOWER,
        GPIO_DEFAULT_OUTPUT), UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
