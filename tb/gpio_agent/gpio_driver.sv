class gpio_driver extends uvm_driver #(gpio_seq_item);
  `uvm_component_utils(gpio_driver)

  virtual gpio_if #(GPIO_NIN, GPIO_NOUT) vif;

  function new(string name = "gpio_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual gpio_if #(GPIO_NIN, GPIO_NOUT))::get(
          this, "", "gpio_vif", vif))
      `uvm_fatal("NOVIF", "gpio_driver did not receive gpio_vif")
  endfunction

  function void drive_idle();
    vif.drv_cb.i_gpio <= '0;
  endfunction

  task wait_for_reset_release();
    while (vif.drv_cb.ARESETN !== 1'b1) begin
      drive_idle();
      @(vif.drv_cb);
    end
  endtask

  task automatic drive_level(gpio_seq_item tr);
    if (vif.drv_cb.ARESETN !== 1'b1) begin
      drive_idle();
      return;
    end

    vif.drv_cb.i_gpio <= tr.value;

    repeat (tr.hold_cycles) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        // Reset aborts the current level/hold operation and returns the pins
        // to their safe idle value.  The sequencer may issue new work after
        // reset is released.
        drive_idle();
        return;
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    gpio_seq_item req;

    drive_idle();
    fork
      begin : drive_items
        forever begin
          wait_for_reset_release();
          seq_item_port.get_next_item(req);
          drive_level(req);
          seq_item_port.item_done();
        end
      end

      begin : reset_watcher
        // Keep reset behavior correct even while get_next_item() is blocked
        // waiting for the sequence to supply another transaction.
        forever begin
          @(vif.drv_cb);
          if (vif.drv_cb.ARESETN !== 1'b1)
            drive_idle();
        end
      end
    join
  endtask
endclass
