// subbytes testbench. reads vectors/roundstep.txt (state + expected outputs
// for all three round steps from the python model) and checks the subbytes
// column for every state.
//
// gui: set tb_subbytes as sim top and Run Simulation. or from the repo root:
//   xvlog -sv rtl/sbox.sv rtl/subbytes.sv tb/tb_subbytes.sv
//   xelab tb_subbytes -s tb_subbytes_sim
//   xsim tb_subbytes_sim -R

`timescale 1ns / 1ps

module tb_subbytes;

    logic [127:0] state_in, state_out;
    logic [127:0] vec_state, exp_sb, exp_sr, exp_mc;
    int fd, n = 0, errors = 0;

    subbytes dut (
        .state_in  (state_in),
        .state_out (state_out)
    );

    initial begin
        // same path fallback as the other tbs (cli runs from repo root, gui
        // copies the file into the sim dir)
        fd = $fopen("vectors/roundstep.txt", "r");
        if (fd == 0) fd = $fopen("roundstep.txt", "r");
        if (fd == 0) begin
            $display("FAIL: can't open roundstep.txt");
            $finish;
        end

        while ($fscanf(fd, "%h %h %h %h", vec_state, exp_sb, exp_sr, exp_mc) == 4) begin
            state_in = vec_state;
            #1;
            if (state_out !== exp_sb) begin
                $display("FAIL: subbytes(%032x) = %032x, expected %032x",
                         vec_state, state_out, exp_sb);
                errors++;
            end
            n++;
        end
        $fclose(fd);

        if (errors == 0)
            $display("PASS: subbytes matches the model on all %0d states", n);
        else
            $display("FAIL: %0d mismatches out of %0d", errors, n);
        $finish;
    end

endmodule
