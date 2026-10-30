class axi4l_v3_stress_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_v3_stress_seq)

  localparam int ID_BASE = 3200;
  localparam int NOUT = axi4l_gpio_tb_cfg_pkg::GPIO_NOUT;
  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;
  axi4l_seq_item requests[$], responses[$], bus_requests[$], bus_responses[$];
  string stages[$];
  bit [31:0] read_expected[$];
  int seen[$], write_order[$], read_order[$];
  int write_pending[$], read_pending[$];
  int write_accepted, read_accepted, write_completed, read_completed;
  int write_returned, read_returned, returned;
  bit [31:0] planned_gpio;
  bit [31:0] planned_mask;

  function new(string name = "axi4l_v3_stress_seq");
    super.new(name);
  endfunction

  function bit [31:0] expected_read(bit [4:0] addr);
    case (addr[4:2])
      0, 1, 2, 3: return planned_gpio;
      6: return planned_mask;
      default: return 0; // GPIO inputs remain zero in this AXI-only test.
    endcase
  endfunction

  function void plan(axi4l_access_e access, bit [4:0] addr,
                     bit [31:0] data, bit [3:0] strb,
                     int delay_cycles, string stage);
    axi4l_seq_item tr;
    int index;
    index = requests.size();
    tr = axi4l_seq_item::type_id::create($sformatf("request_%0d", index));
    tr.access = access;
    tr.addr = addr;
    tr.data = data;
    tr.strb = strb;
    tr.prot = 0;
    tr.aw_delay = 0;
    tr.w_delay = 0;
    tr.ar_delay = 0;
    tr.bready_delay = (access == AXI4L_WRITE) ? delay_cycles : 0;
    tr.rready_delay = (access == AXI4L_READ) ? delay_cycles : 0;
    tr.set_transaction_id(ID_BASE + index);
    requests.push_back(tr);
    responses.push_back(null);
    bus_requests.push_back(null);
    bus_responses.push_back(null);
    stages.push_back(stage);
    seen.push_back(0);
    read_expected.push_back(expected_read(addr));
    if (access == AXI4L_WRITE) begin
      write_order.push_back(index);
      for (int lane = 0; lane < 4; lane++) begin
        if (strb[lane]) begin
          case (addr[4:2])
            0: planned_gpio[lane*8 +: 8] = data[lane*8 +: 8];
            1: planned_gpio[lane*8 +: 8] |= data[lane*8 +: 8];
            2: planned_gpio[lane*8 +: 8] &= ~data[lane*8 +: 8];
            3: planned_gpio[lane*8 +: 8] ^= data[lane*8 +: 8];
            6: planned_mask[lane*8 +: 8] = data[lane*8 +: 8];
            default: begin end
          endcase
        end
      end
      planned_gpio &= (32'hffff_ffff >> (32-NOUT));
      planned_mask &= (32'hffff_ffff >>
                       (32-axi4l_gpio_tb_cfg_pkg::GPIO_NIN));
    end else
      read_order.push_back(index);
  endfunction

  function void build_plan();
    bit [3:0] strb;
    planned_gpio = axi4l_gpio_tb_cfg_pkg::GPIO_DEFAULT_OUTPUT;
    // Each pair contains a real operation and a zero-strobe operation.  The
    // latter still needs a credit and B response, but has no delayed pin side
    // effect when accepted into the DUT's skid buffer.  Existing scoreboard
    // timing models external acceptance rather than internal skid execution.
    for (int i = 0; i < 24; i++) begin
      case (i % 6)
        0: strb = 4'hf;
        1: strb = 4'h1;
        2: strb = 4'h2;
        3: strb = 4'h4;
        4: strb = 4'h8;
        5: strb = 4'h5;
      endcase
      plan(AXI4L_WRITE, (i % 4)*4,
           32'h1357_9bdf ^ (32'h0103_070b * i), strb, 32, "write");
      plan(AXI4L_WRITE, (i % 4)*4, 32'hdead_0000 | i, 0, 0, "write");
    end
    // Read all eight register addresses three times after the write drain.
    // Register values are stable while a second AR waits in the skid buffer.
    for (int i = 0; i < 24; i++)
      plan(AXI4L_READ, (i % 8)*4, 0, 4'hf, 20 + (i % 3), "read");

    for (int i = 0; i < 8; i++) begin
      // The first read has no older R pending, so data is captured at AR
      // acceptance.  A later LOAD changes GPIO while this R is stalled.
      plan(AXI4L_READ, 0, 0, 4'hf, 40, "mixed");
      plan(AXI4L_WRITE, 0, 32'h2000_1000 + i, 4'hf, 24, "mixed");
      plan(AXI4L_READ, 5'h10, 0, 4'hf, 0, "mixed");
      plan(AXI4L_WRITE, 5'h0c, 32'hffff_ffff, 0, 0, "mixed");
    end
  endfunction

  // These callbacks use the existing independent monitor, not Driver IDs.
  // Associate external bus requests with the planned FIFO for each channel.
  function void observe_request(axi4l_seq_item tr);
    int index;
    if (tr.access == AXI4L_WRITE) begin
      if (write_accepted >= write_order.size()) begin
        `uvm_error("STRESS_EXTRA_REQ", "unexpected bus write")
        return;
      end
      index = write_order[write_accepted++];
      write_pending.push_back(index);
    end else begin
      if (read_accepted >= read_order.size()) begin
        `uvm_error("STRESS_EXTRA_REQ", "unexpected bus read")
        return;
      end
      index = read_order[read_accepted++];
      read_pending.push_back(index);
    end
    if (tr.addr != requests[index].addr ||
        (tr.access == AXI4L_WRITE &&
         (tr.data != requests[index].data || tr.strb != requests[index].strb)))
      `uvm_error("STRESS_BUS_REQ_ORDER",
        $sformatf("bus request does not match planned index=%0d", index))
    if (!$cast(bus_requests[index], tr.clone()))
      `uvm_fatal("STRESS_CLONE", "cannot clone bus request")
    `uvm_info("STRESS_BUS_REQ",
      $sformatf("stage=%s %s req_cycle=%0d seq_id=%0d tr_id=%0d addr=0x%02h data=0x%08h strb=%h",
        stages[index], tr.access.name(), tr.accept_cycle,
        requests[index].get_sequence_id(), requests[index].get_transaction_id(),
        tr.addr, tr.data, tr.strb), UVM_NONE)
  endfunction

  function void observe_response(axi4l_seq_item tr);
    int index;
    if (tr.access == AXI4L_WRITE) begin
      if (write_pending.size() == 0) begin
        `uvm_error("STRESS_EXTRA_BUS_RSP", "B without pending write")
        return;
      end
      index = write_pending.pop_front();
      write_completed++;
    end else begin
      if (read_pending.size() == 0) begin
        `uvm_error("STRESS_EXTRA_BUS_RSP", "R without pending read")
        return;
      end
      index = read_pending.pop_front();
      read_completed++;
      if (tr.rdata !== read_expected[index])
        `uvm_error("STRESS_BUS_RDATA",
          $sformatf("tr_id=%0d RDATA=%08h acceptance snapshot=%08h",
            ID_BASE+index, tr.rdata, read_expected[index]))
    end
    if (tr.transaction_id != bus_requests[index].transaction_id ||
        tr.addr != requests[index].addr || tr.resp !== 2'b00)
      `uvm_error("STRESS_BUS_RSP_ORDER", "bus FIFO response association failed")
    if (!$cast(bus_responses[index], tr.clone()))
      `uvm_fatal("STRESS_CLONE", "cannot clone bus response")
  endfunction

  virtual function void response_handler(uvm_sequence_item response);
    axi4l_seq_item rsp;
    int index, expected_index;
    if (!$cast(rsp, response))
      `uvm_fatal("STRESS_RSP_TYPE", "wrong response type")
    index = rsp.get_transaction_id() - ID_BASE;
    if (index < 0 || index >= requests.size()) begin
      `uvm_error("STRESS_UNKNOWN_ID", "unknown UVM transaction ID")
      return;
    end
    seen[index]++;
    returned++;
    if (seen[index] != 1)
      `uvm_error("STRESS_DUPLICATE", "duplicate UVM response")
    if (rsp.access == AXI4L_WRITE) begin
      if (write_returned >= write_order.size())
        `uvm_fatal("STRESS_EXTRA_RSP", "too many write responses")
      expected_index = write_order[write_returned++];
    end else begin
      if (read_returned >= read_order.size())
        `uvm_fatal("STRESS_EXTRA_RSP", "too many read responses")
      expected_index = read_order[read_returned++];
    end
    if (index != expected_index ||
        rsp.get_sequence_id() != requests[index].get_sequence_id() ||
        rsp.access != requests[index].access || rsp.addr != requests[index].addr ||
        rsp.data != requests[index].data || rsp.strb != requests[index].strb)
      `uvm_error("STRESS_UVM_ORDER", "UVM response ID/payload/FIFO order mismatch")
    if (rsp.transaction_aborted || rsp.resp !== 2'b00)
      `uvm_error("STRESS_UVM_STATUS", "unexpected abort or non-OKAY response")
    if (rsp.access == AXI4L_READ && rsp.rdata !== read_expected[index])
      `uvm_error("STRESS_UVM_RDATA", "UVM read response snapshot mismatch")
    if (!$cast(responses[index], rsp.clone()))
      `uvm_fatal("STRESS_CLONE", "cannot clone UVM response")
  endfunction

  task body();
    int checkpoint;
    use_response_handler(1);
    build_plan();
    foreach (requests[i]) begin
      start_item(requests[i]);
      finish_item(requests[i]);
      checkpoint = i+1;
      // No gap inside the 48-write and 24-read bursts.  Drain only at phase
      // boundaries and between mixed epochs, where GPIO changes are checked.
      if (checkpoint == 48 || checkpoint == 72 ||
          (checkpoint > 72 && (checkpoint-72)%4 == 0)) begin
        wait (returned == checkpoint);
        repeat (2) @(vif.mon_cb);
      end
    end
    wait (returned == requests.size());
    repeat (4) @(vif.mon_cb); // Keep routing alive to catch late duplicates.
  endtask

  function void audit();
    foreach (requests[i]) begin
      if (seen[i] != 1 || bus_requests[i] == null ||
          bus_responses[i] == null || responses[i] == null)
        `uvm_error("STRESS_MISSING", $sformatf("incomplete request index=%0d", i))
      else if (responses[i].accept_cycle != bus_requests[i].accept_cycle ||
               responses[i].response_cycle != bus_responses[i].response_cycle)
        `uvm_error("STRESS_CYCLE", "Driver timing differs from independent bus monitor")
    end
    if (returned != requests.size() || write_pending.size() || read_pending.size())
      `uvm_error("STRESS_COUNT", "response count mismatch or bus queues not empty")
    if (write_accepted != write_order.size() || write_completed != write_order.size() ||
        write_returned != write_order.size() || read_accepted != read_order.size() ||
        read_completed != read_order.size() || read_returned != read_order.size())
      `uvm_error("STRESS_TOTALS", "accepted/bus-completed/UVM-returned totals differ")
    `uvm_info("STRESS_SEQ_SUMMARY",
      $sformatf("writes=%0d reads=%0d UVM_responses=%0d bus_B=%0d bus_R=%0d FIFO_empty=%0b",
        write_order.size(), read_order.size(), returned, write_completed,
        read_completed, write_pending.size()==0 && read_pending.size()==0), UVM_NONE)
  endfunction
endclass
