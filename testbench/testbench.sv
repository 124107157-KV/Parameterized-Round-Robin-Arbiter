`timescale 1ns/1ps

`include "uvm_macros.svh"
import uvm_pkg::*;

// ============================================================================
// Testbench configuration
// ============================================================================

`define ARB_N 4

// ============================================================================
// Interface
// ============================================================================

interface arb_if #(
    parameter int N = 4
)(
    input logic clk
);

    logic         rst_n;
    logic [N-1:0] req;
    logic [N-1:0] grant;
    logic         grant_valid;

    // Driver clocking block
    clocking drv_cb @(posedge clk);
        default input #1step output #1ns;
        output req;
        input  rst_n;
        input  grant;
        input  grant_valid;
    endclocking

    // Monitor clocking block
    clocking mon_cb @(posedge clk);
        default input #1step output #1ns;
        input rst_n;
        input req;
        input grant;
        input grant_valid;
    endclocking

    // ------------------------------------------------------------------------
    // Protocol assertions
    // ------------------------------------------------------------------------

    // Grant must be one-hot whenever grant_valid is high.
    property p_grant_onehot;
        @(posedge clk) disable iff (!rst_n)
        grant_valid |-> $onehot(grant);
    endproperty

    assert property (p_grant_onehot)
        else $error("ASSERTION FAILED: grant is not one-hot when grant_valid is high");

    // Grant can only be given to an active requester.
    property p_grant_requested;
        @(posedge clk) disable iff (!rst_n)
        grant_valid |-> ((grant & req) == grant);
    endproperty

    assert property (p_grant_requested)
        else $error("ASSERTION FAILED: grant was given to a requester with req=0");

    // If there are no requests, there must be no grant.
    property p_no_request_no_grant;
        @(posedge clk) disable iff (!rst_n)
        (req == '0) |-> (!grant_valid && grant == '0);
    endproperty

    assert property (p_no_request_no_grant)
        else $error("ASSERTION FAILED: grant generated when req=0");

endinterface

// ============================================================================
// Transaction
// ============================================================================

class arb_item extends uvm_sequence_item;

    rand bit [`ARB_N-1:0] req;

         bit [`ARB_N-1:0] grant;
         bit              grant_valid;
         int unsigned     cycle;

    // Allow idle cycles, but bias random generation toward active requests.
    constraint c_req_distribution {
        req dist {
            4'b0000          := 5,
            [4'b0001:4'b1111] := 95
        };
    }

    `uvm_object_utils_begin(arb_item)
        `uvm_field_int(req,         UVM_ALL_ON)
        `uvm_field_int(grant,       UVM_ALL_ON)
        `uvm_field_int(grant_valid, UVM_ALL_ON)
        `uvm_field_int(cycle,       UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "arb_item");
        super.new(name);
    endfunction

endclass

// ============================================================================
// Directed Sequence
// ============================================================================

class arb_directed_seq extends uvm_sequence #(arb_item);

    `uvm_object_utils(arb_directed_seq)

    function new(string name = "arb_directed_seq");
        super.new(name);
    endfunction

    task send_req(bit [`ARB_N-1:0] r, string label = "directed_item");
        arb_item tr;

        tr = arb_item::type_id::create(label);

        start_item(tr);
        tr.req = r;
        finish_item(tr);
    endtask

    task body();

        `uvm_info(get_type_name(),
                  "Starting directed round-robin arbiter sequence",
                  UVM_LOW)

        // Idle case
        send_req(4'b0000, "idle_no_request");

        // Single requester cases
        send_req(4'b0001, "single_req_0");
        send_req(4'b0010, "single_req_1");
        send_req(4'b0100, "single_req_2");
        send_req(4'b1000, "single_req_3");

        // Two-requester combinations
        send_req(4'b0011, "req_0_1");
        send_req(4'b0101, "req_0_2");
        send_req(4'b1001, "req_0_3");
        send_req(4'b0110, "req_1_2");
        send_req(4'b1010, "req_1_3");
        send_req(4'b1100, "req_2_3");

        // Three-requester combinations
        send_req(4'b0111, "req_0_1_2");
        send_req(4'b1011, "req_0_1_3");
        send_req(4'b1101, "req_0_2_3");
        send_req(4'b1110, "req_1_2_3");

        // All requesters active.
        // Repeating this proves the rotating pointer behavior:
        // expected grants rotate 0 -> 1 -> 2 -> 3 -> 0 ...
        repeat (8) begin
            send_req(4'b1111, "all_requesters_active");
        end

        // Persistent subset cases.
        // These check fairness when only a subset of requesters is active.
        repeat (4) begin
            send_req(4'b0011, "persistent_req_0_1");
        end

        repeat (4) begin
            send_req(4'b1100, "persistent_req_2_3");
        end

        repeat (4) begin
            send_req(4'b1010, "persistent_req_1_3");
        end

        // Return to idle
        send_req(4'b0000, "final_idle");

    endtask

endclass

// ============================================================================
// Constrained-Random Sequence
// ============================================================================

class arb_random_seq extends uvm_sequence #(arb_item);

    `uvm_object_utils(arb_random_seq)

    rand int unsigned n = 300;

    constraint c_n {
        n inside {[50:1000]};
    }

    function new(string name = "arb_random_seq");
        super.new(name);
    endfunction

    task body();
        arb_item tr;

        `uvm_info(get_type_name(),
                  $sformatf("Starting constrained-random sequence with %0d transactions", n),
                  UVM_LOW)

        repeat (n) begin
            tr = arb_item::type_id::create("tr");

            start_item(tr);
            if (!tr.randomize()) begin
                `uvm_error(get_type_name(), "arb_item randomization failed")
            end
            finish_item(tr);
        end
    endtask

endclass

// ============================================================================
// Driver
// ============================================================================

class arb_driver extends uvm_driver #(arb_item);

    `uvm_component_utils(arb_driver)

    virtual arb_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual arb_if)::get(this, "", "vif", vif)) begin
            `uvm_fatal(get_type_name(), "Virtual interface not found")
        end
    endfunction

    task run_phase(uvm_phase phase);
        arb_item tr;

        vif.req <= '0;

        wait (vif.rst_n === 1'b1);

        // Give the DUT one clean cycle after reset release.
        @(vif.drv_cb);

        forever begin
            seq_item_port.get_next_item(tr);

            @(vif.drv_cb);
            vif.drv_cb.req <= tr.req;

            `uvm_info(get_type_name(),
                      $sformatf("DRV: req=%b", tr.req),
                      UVM_HIGH)

            seq_item_port.item_done();
        end
    endtask

endclass

// ============================================================================
// Monitor
// ============================================================================

class arb_monitor extends uvm_monitor;

    `uvm_component_utils(arb_monitor)

    virtual arb_if vif;

    uvm_analysis_port #(arb_item) ap;

    int unsigned cycle_count;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual arb_if)::get(this, "", "vif", vif)) begin
            `uvm_fatal(get_type_name(), "Virtual interface not found")
        end
    endfunction

    task run_phase(uvm_phase phase);
        arb_item tr;

        wait (vif.rst_n === 1'b1);

        forever begin
            @(vif.mon_cb);

            if (vif.mon_cb.rst_n) begin
                tr = arb_item::type_id::create("tr");

                tr.req         = vif.mon_cb.req;
                tr.grant       = vif.mon_cb.grant;
                tr.grant_valid = vif.mon_cb.grant_valid;
                tr.cycle       = cycle_count;

                cycle_count++;

                `uvm_info(get_type_name(),
                          $sformatf("MON: cycle=%0d req=%b grant=%b grant_valid=%0b",
                                    tr.cycle, tr.req, tr.grant, tr.grant_valid),
                          UVM_HIGH)

                ap.write(tr);
            end
        end
    endtask

endclass

// ============================================================================
// Agent
// ============================================================================

class arb_agent extends uvm_agent;

    `uvm_component_utils(arb_agent)

    uvm_sequencer #(arb_item) seqr;
    arb_driver                drv;
    arb_monitor               mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (get_is_active() == UVM_ACTIVE) begin
            seqr = uvm_sequencer #(arb_item)::type_id::create("seqr", this);
            drv  = arb_driver::type_id::create("drv", this);
        end

        mon = arb_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (get_is_active() == UVM_ACTIVE) begin
            drv.seq_item_port.connect(seqr.seq_item_export);
        end
    endfunction

endclass

// ============================================================================
// Scoreboard
// ============================================================================

class arb_scoreboard extends uvm_subscriber #(arb_item);

    `uvm_component_utils(arb_scoreboard)

    int unsigned pointer_ref;

    int unsigned n_checked;
    int unsigned n_pass;
    int unsigned n_fail;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void write(arb_item t);

        bit [`ARB_N-1:0] expected_grant;
        bit              expected_valid;
        int unsigned     expected_idx;

        expected_grant = '0;
        expected_valid = 1'b0;
        expected_idx   = 0;

        // Reference model:
        // Search from pointer_ref and grant the first active requester.
        for (int offset = 0; offset < `ARB_N; offset++) begin
            int unsigned idx;
            idx = (pointer_ref + offset) % `ARB_N;

            if (!expected_valid && t.req[idx]) begin
                expected_grant[idx] = 1'b1;
                expected_valid      = 1'b1;
                expected_idx        = idx;
            end
        end

        n_checked++;

        // Extra protocol checks.
        if (t.grant_valid && !$onehot(t.grant)) begin
            `uvm_error(get_type_name(),
                       $sformatf("Grant is not one-hot: grant=%b", t.grant))
            n_fail++;
        end
        else if (t.grant_valid && ((t.grant & t.req) != t.grant)) begin
            `uvm_error(get_type_name(),
                       $sformatf("Grant given to inactive requester: req=%b grant=%b",
                                 t.req, t.grant))
            n_fail++;
        end
        else if ((t.grant !== expected_grant) ||
                 (t.grant_valid !== expected_valid)) begin
            `uvm_error(get_type_name(),
                       $sformatf("Mismatch at cycle %0d: req=%b expected_valid=%0b expected_grant=%b actual_valid=%0b actual_grant=%b pointer_ref=%0d",
                                 t.cycle,
                                 t.req,
                                 expected_valid,
                                 expected_grant,
                                 t.grant_valid,
                                 t.grant,
                                 pointer_ref))
            n_fail++;
        end
        else begin
            n_pass++;

            `uvm_info(get_type_name(),
                      $sformatf("PASS cycle=%0d req=%b grant=%b pointer_ref=%0d",
                                t.cycle, t.req, t.grant, pointer_ref),
                      UVM_HIGH)
        end

        // Advance reference pointer only when a grant is expected.
        if (expected_valid) begin
            pointer_ref = (expected_idx + 1) % `ARB_N;
        end

    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        if (n_fail == 0) begin
            `uvm_info(get_type_name(),
                      $sformatf("SCOREBOARD PASS: all %0d checked cycles matched expected round-robin behavior",
                                n_checked),
                      UVM_NONE)
        end
        else begin
            `uvm_error(get_type_name(),
                       $sformatf("SCOREBOARD FAIL: checked=%0d pass=%0d fail=%0d",
                                 n_checked, n_pass, n_fail))
        end
    endfunction

endclass

// ============================================================================
// Functional Coverage
// ============================================================================

class arb_coverage extends uvm_subscriber #(arb_item);

    `uvm_component_utils(arb_coverage)

    real coverage_target = 90.0;

    bit [`ARB_N-1:0] sampled_req;
    bit [`ARB_N-1:0] sampled_grant;
    bit              sampled_grant_valid;
    int unsigned     sampled_req_count;
    int unsigned     sampled_grant_index;

    covergroup cg_arbiter;

        option.per_instance = 1;
        option.name         = "round_robin_arbiter_functional_coverage";

        cp_req_pattern : coverpoint sampled_req {
            bins idle       = {4'b0000};

            bins single[]   = {
                4'b0001,
                4'b0010,
                4'b0100,
                4'b1000
            };

            bins two_req[]  = {
                4'b0011,
                4'b0101,
                4'b1001,
                4'b0110,
                4'b1010,
                4'b1100
            };

            bins three_req[] = {
                4'b0111,
                4'b1011,
                4'b1101,
                4'b1110
            };

            bins all_req = {4'b1111};
        }

        cp_req_count : coverpoint sampled_req_count {
            bins zero  = {0};
            bins one   = {1};
            bins two   = {2};
            bins three = {3};
            bins four  = {4};
        }

        cp_grant_valid : coverpoint sampled_grant_valid {
            bins no_grant = {0};
            bins grant    = {1};
        }

        cp_grant_pattern : coverpoint sampled_grant {
            bins no_grant = {4'b0000};
            bins grant_0  = {4'b0001};
            bins grant_1  = {4'b0010};
            bins grant_2  = {4'b0100};
            bins grant_3  = {4'b1000};
        }

        cp_grant_index : coverpoint sampled_grant_index iff (sampled_grant_valid) {
            bins g0 = {0};
            bins g1 = {1};
            bins g2 = {2};
            bins g3 = {3};
        }

        x_req_count_grant_valid : cross cp_req_count, cp_grant_valid;

        x_req_count_grant_index : cross cp_req_count, cp_grant_index;

    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_arbiter = new();
    endfunction

    function automatic int unsigned count_ones(bit [`ARB_N-1:0] value);
        int unsigned count;
        count = 0;

        for (int i = 0; i < `ARB_N; i++) begin
            if (value[i]) begin
                count++;
            end
        end

        return count;
    endfunction

    function automatic int unsigned grant_to_index(bit [`ARB_N-1:0] value);
        for (int i = 0; i < `ARB_N; i++) begin
            if (value[i]) begin
                return i;
            end
        end

        return 0;
    endfunction

    function void write(arb_item t);

        sampled_req         = t.req;
        sampled_grant       = t.grant;
        sampled_grant_valid = t.grant_valid;
        sampled_req_count   = count_ones(t.req);
        sampled_grant_index = grant_to_index(t.grant);

        cg_arbiter.sample();

    endfunction

    function void report_phase(uvm_phase phase);

        real cov;

        super.report_phase(phase);

        cov = cg_arbiter.get_coverage();

        `uvm_info(get_type_name(),
                  $sformatf("COVERAGE SUMMARY: arbiter_functional_coverage=%0.2f%% target=%0.2f%%",
                            cov, coverage_target),
                  UVM_NONE)

        if (cov >= coverage_target) begin
            `uvm_info(get_type_name(),
                      "Coverage target reached",
                      UVM_NONE)
        end
        else begin
            `uvm_warning(get_type_name(),
                         $sformatf("Coverage target not reached: coverage=%0.2f%% target=%0.2f%%",
                                   cov, coverage_target))
        end

    endfunction

endclass

// ============================================================================
// Environment
// ============================================================================

class arb_env extends uvm_env;

    `uvm_component_utils(arb_env)

    arb_agent      agent;
    arb_scoreboard sb;
    arb_coverage   cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        agent = arb_agent::type_id::create("agent", this);
        sb    = arb_scoreboard::type_id::create("sb", this);
        cov   = arb_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        agent.mon.ap.connect(sb.analysis_export);
        agent.mon.ap.connect(cov.analysis_export);
    endfunction

endclass

// ============================================================================
// Test
// ============================================================================

class arb_test extends uvm_test;

    `uvm_component_utils(arb_test)

    arb_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        env = arb_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);

        arb_directed_seq directed_seq;
        arb_random_seq   random_seq;

        directed_seq = arb_directed_seq::type_id::create("directed_seq");
        random_seq   = arb_random_seq::type_id::create("random_seq");

        phase.raise_objection(this);
        phase.phase_done.set_drain_time(this, 50ns);

        `uvm_info(get_type_name(),
                  "Round Robin Arbiter UVM test started",
                  UVM_LOW)

        // Directed tests first: prove edge cases and pointer rotation.
        directed_seq.start(env.agent.seqr);

        // Constrained-random tests: improve coverage and stress the arbiter.
        random_seq.n = 300;
        random_seq.start(env.agent.seqr);

        `uvm_info(get_type_name(),
                  "Round Robin Arbiter UVM test completed",
                  UVM_LOW)

        phase.drop_objection(this);

    endtask

endclass

// ============================================================================
// Top-level testbench module
// ============================================================================

module testbench_top;

    logic clk;

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;

    arb_if #(
        .N(`ARB_N)
    ) vif (
        .clk(clk)
    );

    rr_arbiter #(
        .N(`ARB_N)
    ) dut (
        .clk         (clk),
        .rst_n       (vif.rst_n),
        .req         (vif.req),
        .grant       (vif.grant),
        .grant_valid (vif.grant_valid)
    );

    // Reset generation
    initial begin
        vif.rst_n = 1'b0;
        vif.req   = '0;

        repeat (5) begin
            @(posedge clk);
        end

        vif.rst_n = 1'b1;
    end

    // VCD dump for EPWave
    initial begin
        $dumpfile("dump.vcd");

        $dumpvars(0, testbench_top.clk);
        $dumpvars(0, testbench_top.vif.rst_n);
        $dumpvars(0, testbench_top.vif.req);
        $dumpvars(0, testbench_top.vif.grant);
        $dumpvars(0, testbench_top.vif.grant_valid);
 		// Internal debug signal: round-robin starting pointer
    	$dumpvars(0, testbench_top.dut.pointer_q);
    end

    // Start UVM
    initial begin
        uvm_config_db#(virtual arb_if)::set(null, "*", "vif", vif);

        // You can also run with:
        // +UVM_TESTNAME=arb_test
        run_test("arb_test");
    end

endmodule
