#=
    solve_consumption.jl

Functions to solve the energy consumption of the `building_processes`,
not just the HVAC demand handled in `solve_demand.jl`.
=#

"""
    solve_consumption(
        archetype::ArchetypeBuilding,
        heating_demand_kW::Dict{Object,T} where {T<:SpineDataType},
        cooling_demand_kW::Dict{Object,T} where {T<:SpineDataType};
        mod::Module=@__MODULE__,
    )

Solve the consumption of `archetype.building_processes` based on the `heating_demand_kW` and `cooling_demand_kW`.

NOTE! The `mod` keyword changes from which Module data is accessed from,
`@__MODULE__` by default.

Currently produces only extremely simple estimates,
where each `building_process` is assumed to handle the demand on their output
nodes in full, regardless of what the other `building_processes` are doing.
Thus, the results cannot be used as is for systems with complimentary HVAC
processess, and the merit-order assumptions are left up to the user.

Heating and cooling are handled separately, though.
"""
function solve_consumption(
    archetype::ArchetypeBuilding,
    heating_demand_kW::Dict{Object,T} where {T<:SpineDataType},
    cooling_demand_kW::Dict{Object,T} where {T<:SpineDataType};
    mod::Module=@__MODULE__,
)
    # Map COP modes to their respective demands.
    demand_map_kW = Dict(:heating => heating_demand_kW, :cooling => cooling_demand_kW)

    # Initialize a Dict for storing the results, and convert `hvac_demand`
    # into a parameter value for easier access.
    hvac_consumption_kW = Dict()
    for (process, process_data) in archetype.building_processes
        # Figure out which node the process handles using `maximum_flows_W`
        output_nodes =
            getindex.(
                filter(
                    tup -> tup[1] == mod.direction(:to_node),
                    keys(process_data.maximum_flows_W),
                ),
                2,
            )

        # Calculate the consumption of the process.
        cons_kW = sum(
            demand_map_kW[process_data.coefficient_of_performance_mode][node] /
            process_data.coefficient_of_performance for node in output_nodes;
            init=0.0,
        )
        hvac_consumption_kW[process] = cons_kW

        # Check if HVAC sizing is sufficient
        for ((dir, node), val) in process_data.maximum_flows_W
            max_demand_kW = maximum(values(get(demand_map_kW[process_data.coefficient_of_performance_mode], node, 0)))
            max_cons_kW = maximum(values(cons_kW))
            if dir == mod.direction(:to_node) && max_demand_kW > (val / 1e3)
                @warn """
                Heating demand on node `$(archetype.archetype).$(node)` exceeds maximum power of process `$(process)`!
                 - `maximum_demand_kW`: $(max_demand_kW)
                 - `maximum_flows_kW`: $(val / 1e3)
                """
            elseif dir == mod.direction(:from_node) && max_cons_kW > (val / 1e3)
                @warn """
                Consumption from node `$(archetype.archetype).$(node)` exceeds maximum power of process `$(process)`!
                 - `maximum_cons_kW`: $(max_cons_kW)
                 - `maximum_flows_kW`: $(val / 1e3)
                """
            end
        end
    end
    return hvac_consumption_kW
end
