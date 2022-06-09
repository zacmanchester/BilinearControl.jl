import Pkg; Pkg.activate(joinpath(@__DIR__)); Pkg.instantiate();
using BilinearControl
using BilinearControl.Problems
using BilinearControl.EDMD
import RobotDynamics as RD
using LinearAlgebra
using RobotZoo
using JLD2
using SparseArrays
using Plots
using Distributions
using Distributions: Normal
using Random
using FiniteDiff, ForwardDiff
using StaticArrays
using Test
import TrajectoryOptimization as TO
using Altro
import BilinearControl.Problems

include("learned_models/edmd_utils.jl")

function gencartpoleproblem(x0=zeros(4), Qv=1e-2, Rv=1e-1, Qfv=1e2, u_bnd=3.0, tf=5.0; 
    dt=0.05, constrained=true)

    model = RobotZoo.Cartpole()
    dmodel = RD.DiscretizedDynamics{RD.RK4}(model) 
    n,m = RD.dims(model)
    N = round(Int, tf/dt) + 1

    Q = Qv*Diagonal(@SVector ones(n)) * dt
    Qf = Qfv*Diagonal(@SVector ones(n))
    R = Rv*Diagonal(@SVector ones(m)) * dt
    xf = @SVector [0, pi, 0, 0]
    obj = TO.LQRObjective(Q,R,Qf,xf,N)

    conSet = TO.ConstraintList(n,m,N)
    bnd = TO.BoundConstraint(n,m, u_min=-u_bnd, u_max=u_bnd)
    goal = TO.GoalConstraint(xf)
    if constrained
    TO.add_constraint!(conSet, bnd, 1:N-1)
    TO.add_constraint!(conSet, goal, N:N)
    end

    X0 = [@SVector fill(NaN,n) for k = 1:N]
    u0 = @SVector fill(0.01,m)
    U0 = [u0 for k = 1:N-1]
    Z = TO.SampledTrajectory(X0,U0,dt=dt*ones(N-1))
    prob = TO.Problem(dmodel, obj, x0, tf, constraints=conSet, xf=xf) 
    TO.initial_trajectory!(prob, Z)
    TO.rollout!(prob)
    prob
end

## Visualizer
model = RobotZoo.Cartpole()
include(joinpath(Problems.VISDIR, "visualization.jl"))
vis = Visualizer()
set_cartpole!(vis)
open(vis)

## Solve ALTRO problem
prob = gencartpoleproblem()
solver = ALTROSolver(prob)
Altro.solve!(solver)
visualize!(vis, model, TO.gettimes(solver)[end], TO.states(solver))

## Setup MPC Controller
dmodel = TO.get_model(solver)[1]
X_ref = Vector.(TO.states(solver))
U_ref = Vector.(TO.controls(solver))
push!(U_ref, zeros(RD.control_dim(solver)))
T_ref = TO.gettimes(solver)
Qmpc = Diagonal(fill(1e-0,4))
Rmpc = Diagonal(fill(1e-3,1))
Qfmpc = Diagonal(fill(1e2,4))
Nt = 21 
mpc = TrackingMPC(dmodel, X_ref, U_ref, T_ref, Qmpc, Rmpc, Qfmpc; Nt=Nt)

## Run sim w/ MPC controller
dx = [0.9,deg2rad(-30),0,0.]  # large initial offset
X_sim,U_sim,T_sim = simulatewithcontroller(dmodel, mpc, X_ref[1] + dx, T_ref[end]*1.5, T_ref[2])
plotstates(T_ref, X_ref, inds=1:2, c=:black, legend=:topleft)
plotstates!(T_sim, X_sim, inds=1:2, c=[1 2])

## Define TVLQR Controller
dx = [0.01,0,0,0]
Qtvlqr = [copy(Qmpc) for k in 1:length(X_ref)]
Qtvlqr[end] = copy(Qfmpc) 
Rtvlqr = [Diagonal(fill(1e0,1)) for k in 1:length(X_ref)]
tvlqr_nom = TVLQRController(dmodel, Qtvlqr, Rtvlqr, X_ref, U_ref, T_ref)
X_tvlqr,U_tvlqr,T_tvlqr= simulatewithcontroller(dmodel, tvlqr_nom, X_ref[1] + dx, T_ref[end]*1.5, T_ref[2])

plotstates(T_ref, X_ref, inds=1:2, c=:black, legend=:topleft, ylim=(-4,4), label=["reference" ""],
    xlabel="time (s)", ylabel="states"
)
plotstates!(T_sim, X_sim, inds=1:2, c=[1 2], label=["MPC" ""])
plotstates!(T_tvlqr, X_tvlqr, inds=1:2, c=[1 2], label=["TVLQR" ""], s=:dash)