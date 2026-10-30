class axi4l_gpio_v2_directed_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_gpio_v2_directed_test)

  function new(string name = "axi4l_gpio_v2_directed_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    gpio_level('0, 4);

    // Exercise independent AW/W ordering and every output operation.  Each
    // accepted write creates a separate cycle-tagged GPIO expectation.
    axi_write(5'h00, 32'h0000_00a5, 4'b1111, 0, 2, 3);
    axi_write(5'h04, 32'h0000_0100, 4'b0001, 3, 0, 1);
    axi_write(5'h08, 32'h0000_0004, 4'b1111, 0, 0, 2);
    axi_write(5'h0c, 32'h0000_0030, 4'b0011, 1, 1, 1);
    axi_read (5'h00);

    // INPUT and INT are read-only in this configuration.  Writes complete
    // with OKAY but must not alter output, mask, or sticky status state.
    axi_write(5'h10, 32'hffff_ffff);
    axi_write(5'h1c, 32'hffff_ffff);
    axi_read (5'h00);
    axi_read (5'h18);

    // RTL polarity: MASK bit 1 enables the corresponding sticky interrupt.
    axi_write(5'h18, 32'h0000_0001);
    gpio_level(5'b00001, 6);
    axi_read(5'h10); // synchronized INPUT
    axi_read(5'h14); // sticky CHANGED after rising edge
    axi_read(5'h18); // MASK
    axi_read(5'h1c); // active INT bits

    // Keep CHANGED uncleared while applying both edge directions.  This
    // proves a new edge is handled while o_int is already active.
    gpio_level(5'b00000, 6);
    axi_read(5'h14);
    axi_read(5'h1c);
    gpio_level(5'b00001, 6);
    axi_read(5'h14);
    axi_read(5'h1c);
    gpio_level(5'b00110, 6); // bit0 falls while bits1/2 rise, o_int active
    axi_read(5'h14);
    axi_read(5'h1c);
    gpio_level(5'b00001, 6);

    // CHANGED is W1C and o_int is registered from the prior active vector.
    axi_write(5'h14, 32'h0000_0001, 4'b0001);
    axi_read(5'h14);
    axi_read(5'h1c);

    // After clearing the enabled sticky bit, cover a simultaneous multi-bit
    // rise/fall while the registered interrupt is inactive.
    gpio_level(5'b00110, 6);
    axi_read(5'h14);
    axi_read(5'h1c);
    gpio_level(5'b00000, 6);
    axi_read(5'h10);
    axi_read(5'h14);
    axi_read(5'h1c);

    axi_write(5'h18, 32'h0000_0000, 4'b0001);
    axi_read(5'h18);
    axi_read(5'h1c);
    axi_write(5'h14, 32'h0000_0001, 4'b0001);
    axi_read(5'h14);

    // With MASK=0 in RTL mode, exercise a pure falling edge while interrupt
    // remains inactive, then clear all accumulated sticky bits.
    gpio_level(5'b00010, 6);
    gpio_level(5'b00000, 6);
    axi_read(5'h14);
    axi_read(5'h1c);
    axi_write(5'h14, 32'h0000_001f, 4'b0001);
    axi_read(5'h14);

    gpio_level('0, 2);
    `uvm_info("V2_DIRECTED_DONE",
              "V2 GPIO CDC/change/interrupt directed scenario completed",
              UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
