class axi4l_monitor extends uvm_monitor;
  `uvm_component_utils(axi4l_monitor)

  typedef struct packed {
    bit [AXI4L_ADDR_WIDTH-1:0] addr;
    bit [2:0]                  prot;
    longint unsigned           cycle;
  } aw_sample_t;

  typedef struct packed {
    bit [AXI4L_DATA_WIDTH-1:0]   data;
    bit [AXI4L_DATA_WIDTH/8-1:0] strb;
    longint unsigned             cycle;
  } w_sample_t;

  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;
  // request_ap reports request acceptance; response_ap reports B/R
  // completion.  ap remains as a response-completion compatibility port.
  uvm_analysis_port #(axi4l_seq_item) request_ap;
  uvm_analysis_port #(axi4l_seq_item) response_ap;
  uvm_analysis_port #(axi4l_seq_item) ap;
  uvm_analysis_port #(axi4l_bus_observation) bus_ap;

  aw_sample_t      aw_queue[$];
  w_sample_t       w_queue[$];
  axi4l_seq_item   write_queue[$];
  axi4l_seq_item   read_queue[$];
  int unsigned     write_stall_queue[$];
  int unsigned     read_stall_queue[$];
  longint unsigned sample_cycle;
  longint unsigned next_write_id;
  longint unsigned next_read_id;
  int unsigned     write_highwater;
  int unsigned     read_highwater;
  bit              previous_reset_n;
  bit              reset_exit_observed;

  function new(string name = "axi4l_monitor", uvm_component parent = null);
    super.new(name, parent);
    request_ap  = new("request_ap", this);
    response_ap = new("response_ap", this);
    ap = new("ap", this);
    bus_ap = new("bus_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4l_if #(AXI4L_ADDR_WIDTH,
                                           AXI4L_DATA_WIDTH))::get(
          this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axi4l_monitor did not receive its virtual interface")
  endfunction

  function void clear_queues();
    aw_queue.delete();
    w_queue.delete();
    write_queue.delete();
    read_queue.delete();
    write_stall_queue.delete();
    read_stall_queue.delete();
  endfunction

  function automatic axi4l_reset_context_e classify_reset_context();
    if (vif.mon_cb.BVALID && !vif.mon_cb.BREADY)
      return AXI4L_RESET_B_STALLED;
    if (vif.mon_cb.RVALID && !vif.mon_cb.RREADY)
      return AXI4L_RESET_R_STALLED;
    if ((aw_queue.size() != 0) && (w_queue.size() == 0))
      return AXI4L_RESET_AW_ONLY;
    if ((w_queue.size() != 0) && (aw_queue.size() == 0))
      return AXI4L_RESET_W_ONLY;
    if (write_queue.size() != 0)
      return AXI4L_RESET_WRITE_PENDING;
    if (read_queue.size() != 0)
      return AXI4L_RESET_READ_PENDING;
    return AXI4L_RESET_IDLE;
  endfunction

  function void publish_bus_observation(bit reset_enter,
                                        bit reset_exit,
                                        axi4l_reset_context_e reset_context);
    axi4l_bus_observation observation;
    observation = axi4l_bus_observation::type_id::create("bus_observation");
    observation.sample_cycle = sample_cycle;
    observation.reset_n = vif.mon_cb.ARESETN === 1'b1;
    observation.reset_enter = reset_enter;
    observation.reset_exit = reset_exit;
    observation.reset_context = reset_context;
    observation.aw_handshake = observation.reset_n && vif.mon_cb.AWVALID && vif.mon_cb.AWREADY;
    observation.w_handshake  = observation.reset_n && vif.mon_cb.WVALID  && vif.mon_cb.WREADY;
    observation.ar_handshake = observation.reset_n && vif.mon_cb.ARVALID && vif.mon_cb.ARREADY;
    observation.b_handshake  = observation.reset_n && vif.mon_cb.BVALID  && vif.mon_cb.BREADY;
    observation.r_handshake  = observation.reset_n && vif.mon_cb.RVALID  && vif.mon_cb.RREADY;
    observation.aw_stall = observation.reset_n && vif.mon_cb.AWVALID && !vif.mon_cb.AWREADY;
    observation.w_stall  = observation.reset_n && vif.mon_cb.WVALID  && !vif.mon_cb.WREADY;
    observation.b_stall  = observation.reset_n && vif.mon_cb.BVALID  && !vif.mon_cb.BREADY;
    observation.r_stall  = observation.reset_n && vif.mon_cb.RVALID  && !vif.mon_cb.RREADY;
    observation.write_outstanding = write_queue.size();
    observation.read_outstanding = read_queue.size();
    observation.write_highwater = write_highwater;
    observation.read_highwater = read_highwater;
    bus_ap.write(observation);
  endfunction

  function void publish_request(axi4l_seq_item tr);
    axi4l_seq_item copy;
    if (!$cast(copy, tr.clone()))
      `uvm_fatal("MON_CLONE", "Failed to clone accepted AXI request")
    request_ap.write(copy);
  endfunction

  function void publish_response(axi4l_seq_item tr);
    axi4l_seq_item copy;
    if (!$cast(copy, tr.clone()))
      `uvm_fatal("MON_CLONE", "Failed to clone completed AXI response")
    response_ap.write(copy);

    // Keep the original v1 response-only analysis API available to any
    // external component that still connects monitor.ap.
    if (!$cast(copy, tr.clone()))
      `uvm_fatal("MON_CLONE", "Failed to clone legacy AXI response")
    ap.write(copy);
  endfunction

  task run_phase(uvm_phase phase);
    aw_sample_t aw_sample;
    w_sample_t  w_sample;
    axi4l_seq_item tr;

    clear_queues();
    forever begin
      @(vif.mon_cb);
      sample_cycle++;

      if (vif.mon_cb.ARESETN !== 1'b1) begin
        publish_bus_observation(previous_reset_n, 1'b0,
                                classify_reset_context());
        clear_queues();
        previous_reset_n = 1'b0;
        continue;
      end
      reset_exit_observed = !previous_reset_n;
      previous_reset_n = 1'b1;

      if (vif.mon_cb.AWVALID && vif.mon_cb.AWREADY) begin
        aw_sample.addr = vif.mon_cb.AWADDR;
        aw_sample.prot = vif.mon_cb.AWPROT;
        aw_sample.cycle = sample_cycle;
        aw_queue.push_back(aw_sample);
      end

      if (vif.mon_cb.WVALID && vif.mon_cb.WREADY) begin
        w_sample.data = vif.mon_cb.WDATA;
        w_sample.strb = vif.mon_cb.WSTRB;
        w_sample.cycle = sample_cycle;
        w_queue.push_back(w_sample);
      end

      // Pair the oldest address with the oldest data.  AXI4-Lite has no IDs.
      while ((aw_queue.size() > 0) && (w_queue.size() > 0)) begin
        aw_sample = aw_queue.pop_front();
        w_sample  = w_queue.pop_front();
        tr = axi4l_seq_item::type_id::create("observed_write");
        tr.access = AXI4L_WRITE;
        tr.addr   = aw_sample.addr;
        tr.prot   = aw_sample.prot;
        tr.data   = w_sample.data;
        tr.strb   = w_sample.strb;
        tr.transaction_id = next_write_id++;
        tr.aw_cycle       = aw_sample.cycle;
        tr.w_cycle        = w_sample.cycle;
        tr.accept_cycle   = (aw_sample.cycle > w_sample.cycle)
                          ? aw_sample.cycle : w_sample.cycle;
        write_queue.push_back(tr);
        write_stall_queue.push_back(0);
        if (write_queue.size() > write_highwater)
          write_highwater = write_queue.size();
        tr.outstanding_at_accept = write_queue.size();
        tr.outstanding_highwater = write_highwater;
        publish_request(tr);
      end
      if (vif.mon_cb.BVALID && !vif.mon_cb.BREADY && (write_stall_queue.size() != 0))
        write_stall_queue[0]++;

      if (vif.mon_cb.BVALID && vif.mon_cb.BREADY) begin
        if (write_queue.size() == 0) begin
          `uvm_error("MON_B", "Observed B handshake without a complete AW/W pair")
        end else begin
          tr = write_queue.pop_front();
          tr.response_stall_cycles = write_stall_queue.pop_front();
          tr.resp = vif.mon_cb.BRESP;
          tr.response_cycle = sample_cycle;
          publish_response(tr);
        end
      end

      if (vif.mon_cb.ARVALID && vif.mon_cb.ARREADY) begin
        tr = axi4l_seq_item::type_id::create("observed_read");
        tr.access = AXI4L_READ;
        tr.addr   = vif.mon_cb.ARADDR;
        tr.prot   = vif.mon_cb.ARPROT;
        tr.transaction_id = next_read_id++;
        tr.accept_cycle   = sample_cycle;
        read_queue.push_back(tr);
        read_stall_queue.push_back(0);
        if (read_queue.size() > read_highwater)
          read_highwater = read_queue.size();
        tr.outstanding_at_accept = read_queue.size();
        tr.outstanding_highwater = read_highwater;
        publish_request(tr);
      end
      if (vif.mon_cb.RVALID && !vif.mon_cb.RREADY && (read_stall_queue.size() != 0))
        read_stall_queue[0]++;

      if (vif.mon_cb.RVALID && vif.mon_cb.RREADY) begin
        if (read_queue.size() == 0) begin
          `uvm_error("MON_R", "Observed R handshake without an earlier AR handshake")
        end else begin
          tr = read_queue.pop_front();
          tr.response_stall_cycles = read_stall_queue.pop_front();
          tr.rdata = vif.mon_cb.RDATA;
          tr.resp  = vif.mon_cb.RRESP;
          tr.response_cycle = sample_cycle;
          publish_response(tr);
        end
      end

      publish_bus_observation(1'b0, reset_exit_observed, AXI4L_RESET_IDLE);
    end
  endtask
endclass

