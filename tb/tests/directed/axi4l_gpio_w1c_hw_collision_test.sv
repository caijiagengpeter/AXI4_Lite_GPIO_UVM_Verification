class axi4l_gpio_w1c_hw_collision_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_gpio_w1c_hw_collision_test)

  localparam bit [AXI4L_ADDR_WIDTH-1:0] ADDR_CHANGED = 5'h14;
  localparam int unsigned COLLISION_WRITE_DELAY = 2;

  function new(string name = "axi4l_gpio_w1c_hw_collision_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task automatic clear_changed(bit [GPIO_NIN-1:0] clear_mask);
    bit [AXI4L_DATA_WIDTH-1:0] clear_data;
    clear_data = '0;
    for (int bit_index = 0; bit_index < GPIO_NIN; bit_index++)
      clear_data[bit_index] = clear_mask[bit_index];
    axi_write(ADDR_CHANGED, clear_data, 4'b0001);
  endtask

  task automatic exercise_collision(int unsigned bit_index);
    bit [GPIO_NIN-1:0]         onehot_gpio;
    bit [AXI4L_DATA_WIDTH-1:0] onehot_data;

    onehot_gpio = '0;
    onehot_gpio[bit_index] = 1'b1;
    onehot_data = '0;
    onehot_data[bit_index] = 1'b1;

    // Prove that this source can first create an ordinary sticky event, then
    // clear it while the synchronized GPIO pipeline is stable at baseline.
    gpio_level(onehot_gpio, 6);
    axi_read(ADDR_CHANGED);
    gpio_level('0, 6);
    clear_changed(onehot_gpio);
    axi_read(ADDR_CHANGED);

    // Both sequences start together.  The GPIO pin changes immediately after
    // the launch edge.  The DUT then samples i_gpio -> q -> qq, so the old
    // last/qq values differ on the third sampled edge.  AW/W wait exactly two
    // driver clocking-block events before asserting VALID; with the existing
    // combinational skid-buffer output, write_accept is therefore sampled on
    // that same third edge.  No random delay or internal signal force is used.
    fork
      begin
        gpio_level(onehot_gpio, 6);
      end
      begin
        axi_write(ADDR_CHANGED, onehot_data, 4'b0001,
                  COLLISION_WRITE_DELAY, COLLISION_WRITE_DELAY, 1);
      end
    join

    // The scoreboard snapshots CHANGED from the RTL-equivalent next-state
    // model.  This read proves that hardware-set wins over the same-edge W1C.
    axi_read(ADDR_CHANGED);
    `uvm_info("W1C_HW_COLLISION",
              $sformatf("bit%0d deterministic W1C/hardware-set collision completed",
                        bit_index),
              UVM_NONE)

    // Data=1 with WSTRB=0 must preserve the sticky bit.  This is checked by
    // the independent model and samples the software-data/strobe matrix.
    axi_write(ADDR_CHANGED, onehot_data, 4'b0000);
    axi_read(ADDR_CHANGED);

    // Clear to a stable baseline, then align data=0/WSTRB=1 with a real input
    // change.  Hardware must set the bit even though software writes no clear.
    clear_changed(onehot_gpio);
    gpio_level('0, 6);
    clear_changed(onehot_gpio);
    fork
      begin
        gpio_level(onehot_gpio, 6);
      end
      begin
        axi_write(ADDR_CHANGED, '0, 4'b0001,
                  COLLISION_WRITE_DELAY, COLLISION_WRITE_DELAY, 1);
      end
    join
    axi_read(ADDR_CHANGED);
    `uvm_info("W1C_MATRIX",
      $sformatf("bit%0d covered data1/strobe0 preservation and data0/strobe1/input-change",
                bit_index), UVM_NONE)

    // Return to a clean, fully synchronized baseline.  The falling edge sets
    // CHANGED once more, so wait for it to traverse the pipeline before W1C.
    gpio_level('0, 6);
    clear_changed(onehot_gpio);
    axi_read(ADDR_CHANGED);
  endtask

  task run_phase(uvm_phase phase);
    int unsigned last_bit;

    phase.raise_objection(this);

    // Six stable cycles flush q/qq/last and establish a known clean baseline.
    gpio_level('0, 6);
    clear_changed('1);
    axi_read(ADDR_CHANGED);

    // The plusarg is a diagnostic mode used to validate bit0 alignment before
    // running the identical deterministic schedule for all five input bits.
    last_bit = $test$plusargs("COLLISION_BIT0_ONLY") ? 0 : GPIO_NIN-1;
    for (int unsigned bit_index = 0; bit_index <= last_bit; bit_index++)
      exercise_collision(bit_index);

    `uvm_info("W1C_HW_COLLISION_DONE",
              $sformatf("completed deterministic collision coverage for bits 0..%0d",
                        last_bit),
              UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
