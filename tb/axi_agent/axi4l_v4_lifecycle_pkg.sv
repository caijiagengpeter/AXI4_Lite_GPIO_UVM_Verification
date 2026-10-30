package axi4l_v4_lifecycle_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4l_agent_types_pkg::*;

  typedef enum int unsigned {
    AXI4L_TERMINAL_ACTIVE,
    AXI4L_TERMINAL_NORMAL,
    AXI4L_TERMINAL_ABORTED
  } axi4l_terminal_e;

  typedef enum int unsigned {
    AXI4L_CHANNEL_AW,
    AXI4L_CHANNEL_W,
    AXI4L_CHANNEL_AR
  } axi4l_request_channel_e;

  // Per-request state shared by the future Dispatcher, channel workers,
  // collectors, Reset Coordinator, and Response Publisher.  Immutable
  // request fields are private and can only be read through getters.  The
  // service_* mutators are deliberately narrow: callers must use
  // axi4l_v4_lifecycle_service, which holds lifecycle_lock around them.
  class axi4l_txn_context extends uvm_object;
    `uvm_object_utils(axi4l_txn_context)

    local bit                              m_initialized;
    local axi4l_seq_item                   m_req_snapshot;
    local int                              m_sequence_id;
    local int                              m_uvm_transaction_id;
    local axi4l_access_e                   m_access;
    local longint unsigned                 m_request_id;
    local longint unsigned                 m_order_id;
    local longint unsigned                 m_epoch;
    local bit [AXI4L_ADDR_WIDTH-1:0]        m_addr;
    local bit [AXI4L_DATA_WIDTH-1:0]        m_data;
    local bit [AXI4L_DATA_WIDTH/8-1:0]      m_strb;
    local bit [2:0]                         m_prot;
    local int unsigned                      m_aw_delay;
    local int unsigned                      m_w_delay;
    local int unsigned                      m_ar_delay;
    local int unsigned                      m_bready_delay;
    local int unsigned                      m_rready_delay;

    local bit                              m_dispatch_committed;
    local bit                              m_item_done_sent;
    local bit                              m_cancel_requested;
    local bit                              m_credit_owned;
    local bit                              m_credit_released;
    local bit                              m_aw_handshake;
    local bit                              m_w_handshake;
    local bit                              m_ar_handshake;
    local longint unsigned                 m_aw_cycle;
    local longint unsigned                 m_w_cycle;
    local longint unsigned                 m_accept_cycle;
    local bit                              m_response_handshake;
    local longint unsigned                 m_response_cycle;
    local logic [1:0]                      m_response_resp;
    local logic [AXI4L_DATA_WIDTH-1:0]     m_response_rdata;
    local axi4l_terminal_e                 m_terminal;
    local bit                              m_terminal_enqueued;
    local bit                              m_publication_claimed;
    local bit                              m_response_sent;
    local bit                              m_retired;

    function new(string name = "axi4l_txn_context");
      super.new(name);
      m_terminal      = AXI4L_TERMINAL_ACTIVE;
      m_response_resp = 'x;
      m_response_rdata = 'x;
    endfunction

    function bit initialize(axi4l_seq_item req,
                            longint unsigned request_id,
                            longint unsigned order_id,
                            longint unsigned epoch);
      if (m_initialized || (req == null))
        return 1'b0;
      if (!$cast(m_req_snapshot, req.clone()))
        return 1'b0;
      // clone/copy is not the UVM response association contract.
      m_req_snapshot.set_id_info(req);
      m_req_snapshot.resp                = 'x;
      m_req_snapshot.rdata               = 'x;
      m_req_snapshot.transaction_aborted = 1'b0;

      m_sequence_id        = req.get_sequence_id();
      m_uvm_transaction_id = req.get_transaction_id();
      m_access             = req.access;
      m_request_id         = request_id;
      m_order_id           = order_id;
      m_epoch              = epoch;
      m_addr               = req.addr;
      m_data               = req.data;
      m_strb               = req.strb;
      m_prot               = req.prot;
      m_aw_delay           = req.aw_delay;
      m_w_delay            = req.w_delay;
      m_ar_delay           = req.ar_delay;
      m_bready_delay       = req.bready_delay;
      m_rready_delay       = req.rready_delay;
      m_initialized        = 1'b1;
      return 1'b1;
    endfunction

    function axi4l_seq_item build_response();
      axi4l_seq_item rsp;
      if (!m_initialized || (m_terminal == AXI4L_TERMINAL_ACTIVE))
        return null;
      if (!$cast(rsp, m_req_snapshot.clone()))
        return null;
      rsp.set_id_info(m_req_snapshot);
      rsp.transaction_aborted = (m_terminal == AXI4L_TERMINAL_ABORTED);
      rsp.resp                 = m_response_resp;
      rsp.rdata                = m_response_rdata;
      rsp.aw_cycle             = m_aw_cycle;
      rsp.w_cycle              = m_w_cycle;
      rsp.accept_cycle         = m_accept_cycle;
      rsp.response_cycle       = m_response_cycle;
      return rsp;
    endfunction

    function bit is_initialized(); return m_initialized; endfunction
    function int get_sequence_id_snapshot(); return m_sequence_id; endfunction
    function int get_uvm_transaction_id_snapshot(); return m_uvm_transaction_id; endfunction
    function axi4l_access_e get_access(); return m_access; endfunction
    function longint unsigned get_request_id(); return m_request_id; endfunction
    function longint unsigned get_order_id(); return m_order_id; endfunction
    function longint unsigned get_epoch(); return m_epoch; endfunction
    function bit [AXI4L_ADDR_WIDTH-1:0] get_addr(); return m_addr; endfunction
    function bit [AXI4L_DATA_WIDTH-1:0] get_data(); return m_data; endfunction
    function bit [AXI4L_DATA_WIDTH/8-1:0] get_strb(); return m_strb; endfunction
    function bit [2:0] get_prot(); return m_prot; endfunction
    function int unsigned get_aw_delay(); return m_aw_delay; endfunction
    function int unsigned get_w_delay(); return m_w_delay; endfunction
    function int unsigned get_ar_delay(); return m_ar_delay; endfunction
    function int unsigned get_bready_delay(); return m_bready_delay; endfunction
    function int unsigned get_rready_delay(); return m_rready_delay; endfunction

    function bit get_dispatch_committed(); return m_dispatch_committed; endfunction
    function bit get_item_done_sent(); return m_item_done_sent; endfunction
    function bit get_cancel_requested(); return m_cancel_requested; endfunction
    function bit get_credit_owned(); return m_credit_owned; endfunction
    function bit get_credit_released(); return m_credit_released; endfunction
    function bit get_aw_handshake(); return m_aw_handshake; endfunction
    function bit get_w_handshake(); return m_w_handshake; endfunction
    function bit get_ar_handshake(); return m_ar_handshake; endfunction
    function longint unsigned get_aw_cycle(); return m_aw_cycle; endfunction
    function longint unsigned get_w_cycle(); return m_w_cycle; endfunction
    function longint unsigned get_accept_cycle(); return m_accept_cycle; endfunction
    function longint unsigned get_response_cycle(); return m_response_cycle; endfunction
    function bit get_request_accepted();
      return (m_access == AXI4L_WRITE) ? (m_aw_handshake && m_w_handshake)
                                      : m_ar_handshake;
    endfunction
    function bit get_response_handshake(); return m_response_handshake; endfunction
    function logic [1:0] get_response_resp(); return m_response_resp; endfunction
    function logic [AXI4L_DATA_WIDTH-1:0] get_response_rdata(); return m_response_rdata; endfunction
    function axi4l_terminal_e get_terminal(); return m_terminal; endfunction
    function bit get_terminal_enqueued(); return m_terminal_enqueued; endfunction
    function bit get_publication_claimed(); return m_publication_claimed; endfunction
    function bit get_response_sent(); return m_response_sent; endfunction
    function bit get_retired(); return m_retired; endfunction

    // Service-only mutation points.  Atomicity comes from the lifecycle
    // service's lock, not from these individual functions.
    function void service_mark_dispatch_committed(); m_dispatch_committed = 1'b1; endfunction
    function void service_mark_item_done_sent(); m_item_done_sent = 1'b1; endfunction
    function void service_request_cancel(); m_cancel_requested = 1'b1; endfunction
    function void service_mark_credit_owned(); m_credit_owned = 1'b1; endfunction
    function void service_mark_credit_released(); m_credit_released = 1'b1; endfunction
    function void service_mark_channel(axi4l_request_channel_e channel,
                                       longint unsigned cycle);
      case (channel)
        AXI4L_CHANNEL_AW: begin m_aw_handshake = 1'b1; m_aw_cycle = cycle; end
        AXI4L_CHANNEL_W:  begin m_w_handshake  = 1'b1; m_w_cycle  = cycle; end
        AXI4L_CHANNEL_AR: begin m_ar_handshake = 1'b1; m_accept_cycle = cycle; end
      endcase
      if (m_access == AXI4L_WRITE && m_aw_handshake && m_w_handshake)
        m_accept_cycle = (m_aw_cycle > m_w_cycle) ? m_aw_cycle : m_w_cycle;
    endfunction
    function void service_record_response(logic [1:0] resp,
                                          logic [AXI4L_DATA_WIDTH-1:0] rdata,
                                          longint unsigned cycle);
      m_response_handshake = 1'b1;
      m_response_resp      = resp;
      m_response_rdata     = (m_access == AXI4L_READ) ? rdata : 'x;
      m_response_cycle     = cycle;
    endfunction
    function void service_claim_terminal(axi4l_terminal_e terminal);
      m_terminal = terminal;
      if (terminal == AXI4L_TERMINAL_ABORTED) begin
        m_response_resp  = 'x;
        m_response_rdata = 'x;
      end
      m_terminal_enqueued = 1'b1;
    endfunction
    function void service_claim_publication(); m_publication_claimed = 1'b1; endfunction
    function void service_mark_response_sent(); m_response_sent = 1'b1; endfunction
    function void service_mark_retired(); m_retired = 1'b1; endfunction
  endclass

  // Adapter boundary for the isolated publisher.  Driver integration will
  // provide an implementation that calls seq_item_port.put_response().
  virtual class axi4l_v4_response_sink;
    pure virtual task put_response(input axi4l_seq_item rsp);
  endclass

  class axi4l_v4_lifecycle_service extends uvm_object;
    `uvm_object_utils(axi4l_v4_lifecycle_service)

    local semaphore                         m_lifecycle_lock;
    local semaphore                         m_publisher_lock;
    local semaphore                         m_write_tokens;
    local semaphore                         m_read_tokens;
    local mailbox #(int)                    m_write_wakeup;
    local mailbox #(int)                    m_read_wakeup;
    local mailbox #(int)                    m_item_done_wakeup;
    local mailbox #(axi4l_txn_context)      m_terminal_q;
    local axi4l_txn_context                 m_registry[longint unsigned];
    local axi4l_txn_context                 m_write_order[$];
    local axi4l_txn_context                 m_read_order[$];
    // B2 channel queues are bounded by the corresponding direction credit.
    // The AW/W pair is committed under m_lifecycle_lock, so a worker can
    // never observe only half of a write dispatch.
    local axi4l_txn_context                 m_aw_q[$];
    local axi4l_txn_context                 m_w_q[$];
    local axi4l_txn_context                 m_ar_q[$];
    local int unsigned                      m_max_write;
    local int unsigned                      m_max_read;
    local int unsigned                      m_write_available;
    local int unsigned                      m_read_available;
    local longint unsigned                  m_current_epoch;
    local longint unsigned                  m_next_request_id;
    local longint unsigned                  m_next_write_order;
    local longint unsigned                  m_next_read_order;
    local bit                               m_reset_active;

    function new(string name = "axi4l_v4_lifecycle_service",
                 int unsigned max_write_outstanding = 2,
                 int unsigned max_read_outstanding = 2);
      super.new(name);
      if ((max_write_outstanding == 0) || (max_read_outstanding == 0))
        `uvm_fatal("V4_LIFECYCLE_CFG", "read/write credit maxima must be non-zero")
      m_max_write       = max_write_outstanding;
      m_max_read        = max_read_outstanding;
      m_write_available = max_write_outstanding;
      m_read_available  = max_read_outstanding;
      m_lifecycle_lock  = new(1);
      m_publisher_lock  = new(1);
      m_write_tokens    = new(max_write_outstanding);
      m_read_tokens     = new(max_read_outstanding);
      m_write_wakeup    = new();
      m_read_wakeup     = new();
      m_item_done_wakeup = new();
      m_terminal_q      = new();
    endfunction

    task automatic create_context(input axi4l_seq_item req,
                                  output axi4l_txn_context ctx);
      longint unsigned order_id;
      m_lifecycle_lock.get(1);
      ctx = axi4l_txn_context::type_id::create(
        $sformatf("ctx_%0d", m_next_request_id));
      if (req.access == AXI4L_WRITE) begin
        order_id = m_next_write_order++;
      end else begin
        order_id = m_next_read_order++;
      end
      if (!ctx.initialize(req, m_next_request_id++, order_id, m_current_epoch))
        `uvm_fatal("V4_CTX_INIT", "failed to clone/freeze request context")
      m_registry[ctx.get_request_id()] = ctx;
      if (ctx.get_access() == AXI4L_WRITE)
        m_write_order.push_back(ctx);
      else
        m_read_order.push_back(ctx);
      // A request fetched while reset is already active belongs to no live
      // epoch.  Keep it registered only long enough for Dispatcher item_done
      // and the single Publisher-generated abort response.
      if (m_reset_active) begin
        ctx.service_request_cancel();
        void'(claim_terminal_locked(ctx, AXI4L_TERMINAL_ABORTED));
      end
      m_lifecycle_lock.put(1);
    endtask

    task automatic acquire_credit(input axi4l_txn_context ctx,
                                  output bit acquired);
      bit got_token;
      bit may_wait;
      int wake_token;
      acquired = 1'b0;
      if (ctx == null)
        return;
      forever begin
        if (ctx.get_access() == AXI4L_WRITE)
          got_token = m_write_tokens.try_get(1);
        else
          got_token = m_read_tokens.try_get(1);

        if (got_token) begin
          m_lifecycle_lock.get(1);
          if ((ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE) &&
              !ctx.get_credit_owned() && !m_reset_active &&
              (ctx.get_epoch() == m_current_epoch)) begin
            ctx.service_mark_credit_owned();
            if (ctx.get_access() == AXI4L_WRITE)
              m_write_available--;
            else
              m_read_available--;
            acquired = 1'b1;
          end else begin
            if (ctx.get_access() == AXI4L_WRITE)
              m_write_tokens.put(1);
            else
              m_read_tokens.put(1);
          end
          m_lifecycle_lock.put(1);
          return;
        end

        m_lifecycle_lock.get(1);
        may_wait = ((ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE) &&
                    !m_reset_active &&
                    (ctx.get_epoch() == m_current_epoch));
        m_lifecycle_lock.put(1);
        if (!may_wait)
          return;

        // There is one sequencer Dispatcher, hence at most one credit waiter.
        // Wakeups avoid a blocking semaphore.get surviving a reset epoch.
        if (ctx.get_access() == AXI4L_WRITE)
          m_write_wakeup.get(wake_token);
        else
          m_read_wakeup.get(wake_token);
      end
    endtask

    task automatic mark_dispatch_committed(input axi4l_txn_context ctx,
                                           input longint unsigned expected_epoch,
                                           output bit committed);
      committed = 1'b0;
      m_lifecycle_lock.get(1);
      if ((ctx != null) && !m_reset_active &&
          (ctx.get_epoch() == expected_epoch) &&
          (expected_epoch == m_current_epoch) &&
          (ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE) &&
          !ctx.get_dispatch_committed()) begin
        ctx.service_mark_dispatch_committed();
        committed = 1'b1;
      end
      m_lifecycle_lock.put(1);
    endtask

    // Atomically transfers a credited context into all request-channel
    // queues required by its direction.  Queue capacity equals the credit
    // maximum, so a legitimately credited context must always fit.
    task automatic commit_dispatch(input axi4l_txn_context ctx,
                                   input longint unsigned expected_epoch,
                                   output bit committed);
      bit capacity_ok;
      committed = 1'b0;
      m_lifecycle_lock.get(1);
      capacity_ok = (ctx != null) &&
        ((ctx.get_access() == AXI4L_WRITE)
          ? ((m_aw_q.size() < m_max_write) &&
             (m_w_q.size() < m_max_write))
          :  (m_ar_q.size() < m_max_read));
      if (capacity_ok && !m_reset_active && ctx.get_credit_owned() &&
          (ctx.get_epoch() == expected_epoch) &&
          (expected_epoch == m_current_epoch) &&
          (ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE) &&
          !ctx.get_dispatch_committed()) begin
        if (ctx.get_access() == AXI4L_WRITE) begin
          m_aw_q.push_back(ctx);
          m_w_q.push_back(ctx);
        end else begin
          m_ar_q.push_back(ctx);
        end
        ctx.service_mark_dispatch_committed();
        committed = 1'b1;
      end
      m_lifecycle_lock.put(1);
    endtask

    // Nonblocking worker dequeue.  Each channel has exactly one caller.
    task automatic try_pop_channel(input axi4l_request_channel_e channel,
                                   output axi4l_txn_context ctx,
                                   output bit found);
      found = 1'b0;
      ctx = null;
      m_lifecycle_lock.get(1);
      case (channel)
        AXI4L_CHANNEL_AW: if (m_aw_q.size() != 0) begin
          ctx = m_aw_q.pop_front(); found = 1'b1;
        end
        AXI4L_CHANNEL_W: if (m_w_q.size() != 0) begin
          ctx = m_w_q.pop_front(); found = 1'b1;
        end
        AXI4L_CHANNEL_AR: if (m_ar_q.size() != 0) begin
          ctx = m_ar_q.pop_front(); found = 1'b1;
        end
      endcase
      m_lifecycle_lock.put(1);
    endtask

    // AXI4-Lite has no bus IDs.  Collectors therefore select the oldest live
    // context in direction order, never the context whose worker happened to
    // finish first.  Terminal entries are skipped because they no longer
    // correspond to a response that may be accepted from the bus.
    task automatic find_response_candidate(input axi4l_access_e access,
                                            output axi4l_txn_context ctx,
                                            output bit found);
      found = 1'b0;
      ctx = null;
      m_lifecycle_lock.get(1);
      if (access == AXI4L_WRITE) begin
        foreach (m_write_order[i]) begin
          if (m_write_order[i].get_terminal() == AXI4L_TERMINAL_ACTIVE) begin
            if (m_write_order[i].get_dispatch_committed() &&
                m_write_order[i].get_request_accepted() &&
                !m_write_order[i].get_response_handshake() &&
                (m_write_order[i].get_epoch() == m_current_epoch) &&
                !m_reset_active) begin
              ctx = m_write_order[i]; found = 1'b1;
            end
            break;
          end
        end
      end else begin
        foreach (m_read_order[i]) begin
          if (m_read_order[i].get_terminal() == AXI4L_TERMINAL_ACTIVE) begin
            if (m_read_order[i].get_dispatch_committed() &&
                m_read_order[i].get_request_accepted() &&
                !m_read_order[i].get_response_handshake() &&
                (m_read_order[i].get_epoch() == m_current_epoch) &&
                !m_reset_active) begin
              ctx = m_read_order[i]; found = 1'b1;
            end
            break;
          end
        end
      end
      m_lifecycle_lock.put(1);
    endtask

    // Dispatcher is the sole caller.  Reset only sets cancel_requested; it
    // never calls item_done or claims this flag on the Dispatcher's behalf.
    task automatic claim_item_done(input axi4l_txn_context ctx,
                                   output bit won);
      won = 1'b0;
      m_lifecycle_lock.get(1);
      if ((ctx != null) && !ctx.get_item_done_sent()) begin
        ctx.service_mark_item_done_sent();
        void'(m_item_done_wakeup.try_put(1));
        won = 1'b1;
      end
      m_lifecycle_lock.put(1);
    endtask

    task automatic worker_entry_valid(input axi4l_txn_context ctx,
                                      input longint unsigned expected_epoch,
                                      output bit valid);
      m_lifecycle_lock.get(1);
      valid = ((ctx != null) && !m_reset_active &&
               (ctx.get_epoch() == expected_epoch) &&
               (expected_epoch == m_current_epoch) &&
               (ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE));
      m_lifecycle_lock.put(1);
    endtask

    task automatic mark_channel_handshake(
      input axi4l_txn_context ctx,
      input axi4l_request_channel_e channel,
      input longint unsigned expected_epoch,
      input bit reset_sampled_high,
      input longint unsigned cycle,
      output bit recorded);
      bit channel_matches_access;
      bit channel_not_recorded;
      recorded = 1'b0;
      m_lifecycle_lock.get(1);
      channel_matches_access =
        (((channel == AXI4L_CHANNEL_AW) || (channel == AXI4L_CHANNEL_W)) &&
         (ctx != null) && (ctx.get_access() == AXI4L_WRITE)) ||
        ((channel == AXI4L_CHANNEL_AR) &&
         (ctx != null) && (ctx.get_access() == AXI4L_READ));
      channel_not_recorded = (ctx != null) &&
        (((channel == AXI4L_CHANNEL_AW) && !ctx.get_aw_handshake()) ||
         ((channel == AXI4L_CHANNEL_W)  && !ctx.get_w_handshake())  ||
         ((channel == AXI4L_CHANNEL_AR) && !ctx.get_ar_handshake()));
      if (channel_matches_access && channel_not_recorded &&
          reset_sampled_high && !m_reset_active &&
          (ctx.get_epoch() == expected_epoch) &&
          (expected_epoch == m_current_epoch) &&
          (ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE)) begin
        ctx.service_mark_channel(channel, cycle);
        recorded = 1'b1;
      end
      m_lifecycle_lock.put(1);
    endtask

    // Collector sampling boundary: call in the same drv_cb observation that
    // sees VALID&&READY.  reset_sampled_high must be (ARESETN === 1'b1).
    // A low/X reset sample cannot become NORMAL.  Once recorded, later reset
    // sweeps skip this context even if publication has not happened yet.
    task automatic record_response_handshake(
      input axi4l_txn_context ctx,
      input longint unsigned expected_epoch,
      input bit reset_sampled_high,
      input logic [1:0] resp,
      input logic [AXI4L_DATA_WIDTH-1:0] rdata,
      input longint unsigned cycle,
      output bit recorded);
      recorded = 1'b0;
      m_lifecycle_lock.get(1);
      if ((ctx != null) && reset_sampled_high && !m_reset_active &&
          (ctx.get_epoch() == expected_epoch) &&
          (expected_epoch == m_current_epoch) &&
          (ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE) &&
          ctx.get_request_accepted() &&
          !ctx.get_response_handshake()) begin
        ctx.service_record_response(resp, rdata, cycle);
        recorded = 1'b1;
      end
      m_lifecycle_lock.put(1);
    endtask

    local function bit claim_terminal_locked(input axi4l_txn_context ctx,
                                             input axi4l_terminal_e terminal);
      if ((ctx == null) || (terminal == AXI4L_TERMINAL_ACTIVE) ||
          (ctx.get_terminal() != AXI4L_TERMINAL_ACTIVE))
        return 1'b0;
      if ((terminal == AXI4L_TERMINAL_NORMAL) &&
          !ctx.get_response_handshake())
        return 1'b0;
      if ((terminal == AXI4L_TERMINAL_ABORTED) &&
          ctx.get_response_handshake())
        return 1'b0;
      ctx.service_claim_terminal(terminal);
      if (!m_terminal_q.try_put(ctx))
        `uvm_fatal("V4_TERMINAL_Q", "unbounded terminal queue rejected an entry")
      return 1'b1;
    endfunction

    task automatic claim_terminal(input axi4l_txn_context ctx,
                                  input axi4l_terminal_e terminal,
                                  output bit won);
      m_lifecycle_lock.get(1);
      won = claim_terminal_locked(ctx, terminal);
      m_lifecycle_lock.put(1);
    endtask

    task automatic record_normal_completion(
      input axi4l_txn_context ctx,
      input longint unsigned expected_epoch,
      input bit reset_sampled_high,
      input logic [1:0] resp,
      input logic [AXI4L_DATA_WIDTH-1:0] rdata,
      input longint unsigned cycle,
      output bit won);
      won = 1'b0;
      m_lifecycle_lock.get(1);
      if ((ctx != null) && reset_sampled_high && !m_reset_active &&
          (ctx.get_epoch() == expected_epoch) &&
          (expected_epoch == m_current_epoch) &&
          (ctx.get_terminal() == AXI4L_TERMINAL_ACTIVE) &&
          ctx.get_request_accepted() &&
          !ctx.get_response_handshake()) begin
        ctx.service_record_response(resp, rdata, cycle);
        won = claim_terminal_locked(ctx, AXI4L_TERMINAL_NORMAL);
      end
      m_lifecycle_lock.put(1);
    endtask

    task automatic begin_reset_and_abort(output longint unsigned new_epoch);
      m_lifecycle_lock.get(1);
      m_reset_active = 1'b1;
      m_current_epoch++;
      new_epoch = m_current_epoch;
      foreach (m_write_order[i]) begin
        if ((m_write_order[i].get_terminal() == AXI4L_TERMINAL_ACTIVE) &&
            (m_write_order[i].get_epoch() < m_current_epoch)) begin
          m_write_order[i].service_request_cancel();
          if (!m_write_order[i].get_response_handshake())
            void'(claim_terminal_locked(m_write_order[i],
                                        AXI4L_TERMINAL_ABORTED));
        end
      end
      foreach (m_read_order[i]) begin
        if ((m_read_order[i].get_terminal() == AXI4L_TERMINAL_ACTIVE) &&
            (m_read_order[i].get_epoch() < m_current_epoch)) begin
          m_read_order[i].service_request_cancel();
          if (!m_read_order[i].get_response_handshake())
            void'(claim_terminal_locked(m_read_order[i],
                                        AXI4L_TERMINAL_ABORTED));
        end
      end
      // Queued entries lose queue ownership here.  In-flight workers retain
      // handles but epoch validation prevents any further drive/handshake.
      m_aw_q.delete();
      m_w_q.delete();
      m_ar_q.delete();
      // Wake the single Dispatcher if it was waiting for either direction.
      void'(m_write_wakeup.try_put(1));
      void'(m_read_wakeup.try_put(1));
      m_lifecycle_lock.put(1);
    endtask

    task automatic end_reset();
      m_lifecycle_lock.get(1);
      m_reset_active = 1'b0;
      m_lifecycle_lock.put(1);
    endtask

    local function void retire_context_locked(input axi4l_txn_context ctx);
      m_registry.delete(ctx.get_request_id());
      if (ctx.get_access() == AXI4L_WRITE) begin
        foreach (m_write_order[i]) begin
          if (m_write_order[i] == ctx) begin
            m_write_order.delete(i);
            break;
          end
        end
      end else begin
        foreach (m_read_order[i]) begin
          if (m_read_order[i] == ctx) begin
            m_read_order.delete(i);
            break;
          end
        end
      end
      ctx.service_mark_retired();
    endfunction

    // Single physical publisher path.  Ordering is intentional:
    // sink.put_response -> response_sent -> credit return -> registry retire.
    task automatic publish_next(input axi4l_v4_response_sink sink,
                                output axi4l_txn_context published_ctx);
      axi4l_txn_context ctx;
      axi4l_seq_item rsp;
      bit release_credit;
      bit item_done_ready;
      int wake_token;
      if (sink == null)
        `uvm_fatal("V4_PUBLISH", "response sink is null")
      m_publisher_lock.get(1);
      m_terminal_q.get(ctx);
      // A reset may decide ABORT before the Dispatcher has performed the
      // request-side item_done.  Publication waits; it never steals that
      // ownership and never lets put_response overtake item_done.
      item_done_ready = 1'b0;
      while (!item_done_ready) begin
        m_lifecycle_lock.get(1);
        item_done_ready = ctx.get_item_done_sent();
        if (item_done_ready) begin
          if (ctx.get_publication_claimed() || ctx.get_response_sent())
            `uvm_fatal("V4_PUBLISH", "duplicate publication claim")
          ctx.service_claim_publication();
        end
        m_lifecycle_lock.put(1);
        if (!item_done_ready)
          m_item_done_wakeup.get(wake_token);
      end

      rsp = ctx.build_response();
      if (rsp == null)
        `uvm_fatal("V4_PUBLISH", "failed to build terminal response")
      sink.put_response(rsp);

      m_lifecycle_lock.get(1);
      ctx.service_mark_response_sent();
      release_credit = ctx.get_credit_owned() && !ctx.get_credit_released();
      if (release_credit) begin
        ctx.service_mark_credit_released();
        if (ctx.get_access() == AXI4L_WRITE) begin
          m_write_available++;
          m_write_tokens.put(1);
          void'(m_write_wakeup.try_put(1));
        end else begin
          m_read_available++;
          m_read_tokens.put(1);
          void'(m_read_wakeup.try_put(1));
        end
      end
      retire_context_locked(ctx);
      m_lifecycle_lock.put(1);
      published_ctx = ctx;
      m_publisher_lock.put(1);
    endtask

    // Reusable guard used only by the Publisher path; exposed for focused
    // invariant tests.  A second attempt must return released=0.
    task automatic release_credit_once(input axi4l_txn_context ctx,
                                       output bit released);
      released = 1'b0;
      m_lifecycle_lock.get(1);
      if ((ctx != null) && ctx.get_response_sent() &&
          ctx.get_credit_owned() && !ctx.get_credit_released()) begin
        ctx.service_mark_credit_released();
        if (ctx.get_access() == AXI4L_WRITE) begin
          m_write_available++;
          m_write_tokens.put(1);
          void'(m_write_wakeup.try_put(1));
        end else begin
          m_read_available++;
          m_read_tokens.put(1);
          void'(m_read_wakeup.try_put(1));
        end
        released = 1'b1;
      end
      m_lifecycle_lock.put(1);
    endtask

    task automatic get_snapshot(output longint unsigned epoch,
                                output bit reset_active,
                                output int unsigned write_available,
                                output int unsigned read_available,
                                output int unsigned write_owned,
                                output int unsigned read_owned,
                                output int unsigned registry_count,
                                output int unsigned terminal_depth);
      write_owned = 0;
      read_owned  = 0;
      m_lifecycle_lock.get(1);
      foreach (m_registry[id]) begin
        if (m_registry[id].get_credit_owned() &&
            !m_registry[id].get_credit_released()) begin
          if (m_registry[id].get_access() == AXI4L_WRITE)
            write_owned++;
          else
            read_owned++;
        end
      end
      epoch           = m_current_epoch;
      reset_active    = m_reset_active;
      write_available = m_write_available;
      read_available  = m_read_available;
      registry_count  = m_registry.num();
      terminal_depth  = m_terminal_q.num();
      m_lifecycle_lock.put(1);
    endtask

    task automatic get_queue_snapshot(output int unsigned aw_depth,
                                      output int unsigned w_depth,
                                      output int unsigned ar_depth);
      m_lifecycle_lock.get(1);
      aw_depth = m_aw_q.size();
      w_depth  = m_w_q.size();
      ar_depth = m_ar_q.size();
      m_lifecycle_lock.put(1);
    endtask

    task automatic lookup_context(input longint unsigned request_id,
                                  output bit found,
                                  output axi4l_txn_context ctx);
      m_lifecycle_lock.get(1);
      found = m_registry.exists(request_id);
      ctx = found ? m_registry[request_id] : null;
      m_lifecycle_lock.put(1);
    endtask

    task automatic check_invariants(output bit ok);
      longint unsigned epoch;
      bit reset_active;
      int unsigned write_available;
      int unsigned read_available;
      int unsigned write_owned;
      int unsigned read_owned;
      int unsigned registry_count;
      int unsigned terminal_depth;
      get_snapshot(epoch, reset_active, write_available, read_available,
                   write_owned, read_owned, registry_count, terminal_depth);
      ok = ((write_available + write_owned) == m_max_write) &&
           ((read_available + read_owned) == m_max_read) &&
           (write_available <= m_max_write) &&
           (read_available <= m_max_read);
    endtask
  endclass
endpackage
