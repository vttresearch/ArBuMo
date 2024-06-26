#=
    solve_demand.jl

Functions for solving the heating/cooling demands of `ArchetypeBuilding`s.
=#


"""
    solve_heating_demand(
        archetype::ArchetypeBuilding;
        realization::Symbol=:realization,
        free_dynamics::Bool=false,
        initial_temperatures::Nothing=nothing,
    )

Solve the heating/cooling demand of the `archetype`.

Note that this function calculates the "final energy demand" of the archetype
building, and not the energy consumption of it's HVAC systems.
See the [`solve_consumption`](@ref) function for that.
Furthermore, the calculations are deterministic, with `realization` defining
the true data from potentially stochastic input.
Essentially, performs the following steps:
1. Check external load data and [`determine_temporal_structure`](@ref).
2. Initialize external load an thermal mass vectors using [`initialize_rhs`](@ref).
3. Initialize temperature and temperature limit vectors using [`initialize_temperatures`](@ref).
4. Solve the heating demand using [`solve_heating_demand_loop`](@ref).
5. Rearrange the solution into `Dict`s.
6. [`calculate_final_heating_demand`](@ref) by applying the thermal mass dynamic correction to the preliminary heating and cooling demand from ArBuWe.py.

Uses an extremely simple rule-based control to solve the heating/cooling
demand of the archetype building. The controller intervenes
whenever node temperatures would deviate from permitted limits,
and provides the required energy input to maintain the system at the limit.

The building dynamics are discretized using implicit *(backwards)* Euler,
mainly for consistency with our existing energy system modelling tools
like Backbone or SpineOpt. In principle, I the system could be solved
analytically similar to my Master's Thesis, if better accuracy would be desired:
*Energy Management in Households with Coupled Photovoltaics and Electric Vehicles, Topi Rasku, 2015, Aalto University School of Science*.

The idea of solving heating demand calculations can be as follows,
starting from the energy balance equation for node `n`
```math
C_n \\frac{dT_n(t)}{dt} = - \\rho_n T_n(t) + \\sum_{m \\in N} \\left[ H_{n,m} \\left( T_m(t) - T_n(t) \\right) \\right] + \\Phi_n(t),
```
where `C_n` is the heat capacity of node `n`,
`T_n(t)` is the time-dependent temperature of node `n` at time `t`,
`ρ_n` is the self-discharge from node `n`,
`N` is the set of temperature nodes in the lumped-capacitance model of the building,
`H_n,m` is the heat transfer coefficient between nodes `n` and `m`,
and `Φ_n(t)` is the time-dependent total external heat load on node `n`.
Using the implicit Euler discretization, the above can be cast into
```math
\\left( \\frac{C_n}{\\Delta t} + \\rho_n + \\sum_{m \\in N} H_{n,m} \\right) T_{n,t} - \\sum_{m \\in N} \\left[ H_{n,m} T_{m,t} \\right] = \\Phi_{n,t} + \\frac{C_n}{\\Delta t} T_{n,t-\\Delta t},
```
where `Δt` is the length of the discretized time step.
Since we always know the temperatures on the previous time step `t-Δt`,
the above can be expressed in matrix form and solved as
```math
\\bm{A} \\hat{T} = \\hat{\\Phi}, \\\\
\\hat{T} = \\bm{A}^{-1} \\hat{\\Phi},
```
where `A` is the so-called *dynamics matrix*, 
`T` is the current temperature vector,
and `Φ` is the right-hand side vector, containing the effect of external loads
and previous temperatures.

The above is used to calculate the temperatures of the nodes on each subsequent
time step. However, when any of the node temperatures would violate the defined
minimum and maximum permitted temperatures, that temperature variable is instead
fixed to the violated boundary, moved to the right-hand side,
and replaced with a heating/cooling demand variable `ϕ_m` instead.
This results in a slightly modified problem to be solved
```math
\\hat{\\phi} = \\left( \\bm{A} - \\sum_{m \\in M}[\\bm{A}_{m} + \\bm{I}_{m}] \\right)^{-1} \\left( \\hat{\\Phi} - \\sum_{m \\in M}[\\hat{A}_{m} T'_m] \\right),
```
where `ϕ` is the modified temperature vector with the fixed temperature replaced
with the heating/cooling demand variable,
`m ∈ M` are the nodes that would violate their permitted bounds,
and are therefore fixed at the boundary `T'_m`,
`A_m` represents a selection of column `m` from the matrix `A`,
and `I_m` represents column `m` from an identity matrix.
Please note that there are both matrix and vector selections of `A_m`,
where the matrix selection preserves the dimensions with filling zeroes,
while the vector selection is essentially only the selected column in vector form.

The final heating and cooling demand is calculated based on the preliminary
heating and cooling demand obtained from ArBuWe.py, with a correction applied
using the simulated node temperatures and heat transfers.
"""
function solve_heating_demand(
    archetype::ArchetypeBuilding;
    realization::Symbol=:realization,
    free_dynamics::Bool=false,
    initial_temperatures::Nothing=nothing,
)
    # Categorize nodes based on their role.
    (air_node, air_node_data) =
        only(filter(pair -> pair[2].is_interior_node, archetype.abstract_nodes))
    free_nodes =
        filter(pair -> isnothing(pair[2].heating_set_point_K), archetype.abstract_nodes)

    # Determine the temporal structure
    indices, delta_t = determine_temporal_structure(archetype; realization=realization)

    # Initialize the external load and thermal mass vectors.
    external_load_vector, thermal_mass_vector =
        initialize_rhs(archetype, indices, delta_t; realization=realization)

    # Initialize the temperature vector and the temperature limit vectors.
    init_temperatures, min_temperatures, max_temperatures = initialize_temperatures(
        archetype,
        indices,
        delta_t,
        external_load_vector,
        thermal_mass_vector,
        free_dynamics,
        initial_temperatures,
    )

    # Solve the heating demand for the entire set of indices.
    temperatures, hvac_demand = solve_heating_demand_loop(
        archetype,
        indices,
        delta_t,
        init_temperatures,
        min_temperatures,
        max_temperatures,
        external_load_vector,
        thermal_mass_vector,
        free_dynamics,
    )

    # Rearrange the results into Dicts,
    # and remove initial values from the temperature array.
    nodes = keys(archetype.abstract_nodes)
    temp_dict = Dict(
        zip(
            nodes,
            [
                TimeSeries(indices, getindex.(temperatures, i), false, false) for
                (i, n) in enumerate(nodes)
            ],
        ),
    )
    heating_demand_dict_kW = Dict(
        zip(
            nodes,
            [
                TimeSeries(indices, max.(getindex.(hvac_demand, i), 0.0) ./ 1e3, false, false) for
                (i, n) in enumerate(nodes)
            ],
        ),
    )
    cooling_demand_dict_kW = Dict(
        zip(
            nodes,
            [
                TimeSeries(indices, -min.(getindex.(hvac_demand, i), 0.0) ./ 1e3, false, false) for
                (i, n) in enumerate(nodes)
            ],
        ),
    )

    # Calculate the heating demand for the indoor air node
    heating_demand_kW, cooling_demand_kW, heating_correction_W, cooling_correction_W =
        calculate_final_heating_demand(archetype, temp_dict, air_node, free_nodes)

    # Calculate the final heating-to-cooling demand ratio.
    hc_ratio = heating_demand_kW / (heating_demand_kW + cooling_demand_kW)
    replace!(x -> isnan(x) ? 0.5 : x, values(hc_ratio))

    # Replace indoor air node heating and cooling demands.
    heating_demand_dict_kW[air_node] = heating_demand_kW
    cooling_demand_dict_kW[air_node] = cooling_demand_kW

    return temp_dict,
    heating_demand_dict_kW,
    cooling_demand_dict_kW,
    heating_correction_W,
    cooling_correction_W,
    hc_ratio
end


"""
    determine_temporal_structure(
        archetype::ArchetypeBuilding;
        realization::Symbol=:realization,
    )

Check that `external_load_W` timeseries are consistent in the `AbstractNodeNetwork`,
and determine the time series indices and the `delta_t`.

Note that the time series need to have a constant `delta_t`.
The `realization` keyword is necessary to indicate the true data from potentially
stochastic input.
"""
function determine_temporal_structure(
    archetype::ArchetypeBuilding;
    realization::Symbol=:realization,
)
    # Check that all nodes have identical `external_load_W` time series indices.
    indices = keys(
        parameter_value(first(archetype.abstract_nodes)[2].external_load_W)(
            scenario=realization,
        ),
    )
    if !all(
        keys(parameter_value(n.external_load_W)(scenario=realization)) == indices for
        (k, n) in archetype.abstract_nodes
    )
        return @error """
        `external_load_W` time series are indexed different for `abstract_nodes`
        of `archetype_building` `$(archetype)`!
        """
    end

    # Indices must be a Vector{DateTime}, 24-hours simulated by default.
    if !isa(indices, Vector{DateTime})
        indices = [DateTime(2) + Hour(i) for i = 0:23]
    end

    # Calculate the delta t in hours, all time steps need to have constant value.
    delta_t = getfield.(Hour.(diff(indices)), :value)
    if !all(delta_t .== first(delta_t))
        return @error """
        `external_load_W` time series of `archetype` `$(archetype)` must have
        a constant time step length!
        """
    end
    return indices, first(delta_t)
end


"""
    form_and_invert_dynamics_matrix(
        archetype::ArchetypeBuilding,
        t::DateTime,
        delta_t::Int64,
    )

Forms and inverts the implicit Euler discretized dynamics matrix for the
`AbstractNodeNetwork`.

The implicit Euler discretized dynamics matrix `A` is formed as follows:
```math
\\bm{A}_{n,m} = \\begin{cases}
\\frac{C_m}{\\Delta t} + \\rho_m + \\sum_{n' \\in N} H_{n,m}, \\qquad n = m, \\\\
- H_{n,m}, \\qquad n \\neq m,
\\end{cases}, \\quad \\text{where } n, m \\in N
```
where `A_n,m` is the element of the dynamic matrix `A` on row `n` and column `m`,
`C_m` is the thermal mass of node `m`,
`Δt` is the length of the discretized time step,
`ρ_m` is the self-discharge coefficient of node `m`,
`N` is the set of nodes included in the lumped-capacitance thermal model,
and `H_{m,n}` is the heat transfer coefficient between nodes `n` and `m`.
"""
function form_and_invert_dynamics_matrix(
    archetype::ArchetypeBuilding,
    t::DateTime,
    delta_t::Int64,
)
    # Initialize the implicit Euler dynamics matrix.
    len = length(archetype.abstract_nodes)
    M = Matrix{Float64}(undef, len, len)

    # Loop over the matrix to fill in the values.
    enum_nodes = enumerate(archetype.abstract_nodes)
    for (i, (k1, n1)) in enum_nodes
        for (j, (k2, n2)) in enum_nodes
            if i == j
                M[i, j] =
                    n1.thermal_mass_Wh_K / delta_t +
                    parameter_value(n1.self_discharge_coefficient_W_K)(t=t) +
                    sum(values(n1.heat_transfer_coefficients_W_K); init=0.0)
            else
                M[i, j] = -get(n1.heat_transfer_coefficients_W_K, k2, 0.0)
            end
        end
    end

    # Return the dynamics matrix and its inverse
    return M, inv(M)
end


"""
    initialize_rhs(
        archetype::ArchetypeBuilding,
        indices::Vector{Dates.DateTime},
        delta_t::Int64;
        realization::Symbol=:realization,
    )

Initialize the right-hand side of the linear equation system,
meaning the impact of the `external_load_W` and previous temperatures.

The `realization` keyword is used to indicate the true data from potentially
stochastic input.

See the [`solve_heating_demand`](@ref) function for the overall formulation.
This function returns the right-hand side components separately
```math
\\hat{\\Phi} = \\hat{\\Phi'} + \\hat{\\frac{C}{\\Delta t} T_{t-\\Delta t}},
```
where `Φ'` is the component of external loads,
and the rest is the component of the impact of previous temperatures.
The components are useful for the [`solve_heating_demand_loop`](@ref) function.
"""
function initialize_rhs(
    archetype::ArchetypeBuilding,
    indices::Vector{Dates.DateTime},
    delta_t::Int64;
    realization::Symbol=:realization,
)
    # Process the nodal `external_load_W`s into a nested vector for easy access.
    external_load_vector = [
        [
            parameter_value(n.external_load_W)(scenario=realization, t=t) for
            (k, n) in archetype.abstract_nodes
        ] for (i, t) in enumerate(indices)
    ]

    # Calculate the thermal mass vector to account for previous temperatures.
    thermal_mass_vector =
        [n.thermal_mass_Wh_K / delta_t for (k, n) in archetype.abstract_nodes]

    return external_load_vector, thermal_mass_vector
end


"""
    initialize_temperatures(
        archetype::ArchetypeBuilding,
        indices::Vector{DateTime},
        delta_t::Int64,
        external_load_vector::Vector{Vector{Float64}},
        thermal_mass_vector::Vector{Float64},
        free_dynamics::Bool,
        initial_temperatures::Union{Nothing,Dict{Object,Float64}},
    )

Initialize the temperature and temperature limit vectors for the heating/cooling
demand calculations.

Initial temperatures are solved by repeatedly solving the first 24 hours
until the end-result no longer changes.
The initialization is abandoned if no stable initial temperatures are found
within a thousand 24-hour solves.
In this case, the minimum permitted temperatures are used as the initial
temperatures for each node, unless otherwise specified via `initial_temperatures`.
Internally, uses the [`solve_heating_demand_loop`](@ref) function.

See the [`solve_heating_demand`](@ref) function for the overall logic and
formulation of the heating demand calculations.
"""
function initialize_temperatures(
    archetype::ArchetypeBuilding,
    indices::Vector{DateTime},
    delta_t::Int64,
    external_load_vector::Vector{Vector{Float64}},
    thermal_mass_vector::Vector{Float64},
    free_dynamics::Bool,
    initial_temperatures::Union{Nothing,Dict{Object,Float64}},
)
    # Fetch the allowed temperature limits.
    min_temperatures = Vector{SpineDataType}([
        !isnothing(n.heating_set_point_K) ?
        n.heating_set_point_K :
        200.0
        for (k, n) in archetype.abstract_nodes
    ])
    max_temperatures = Vector{SpineDataType}([
        !isnothing(n.cooling_set_point_K) ?
        n.cooling_set_point_K :
        400.0
        for (k, n) in archetype.abstract_nodes
    ])

    # Form the initial temperature vector.
    # Based on minimum temperatures unless otherwise defined.
    if !isnothing(initial_temperatures)
        init_temperatures =
            float.(
                get(initial_temperatures, n, first(values(min_temperatures[i]))) for
                (i, n) in enumerate(keys(archetype.abstract_nodes))
            )
        min_init_temperatures = deepcopy(min_temperatures)
        max_init_temperatures = deepcopy(max_temperatures)
        fixed_inds = findall(init_temperatures .!= first.(values.(min_temperatures)))
        max_init_temperatures[fixed_inds] = init_temperatures[fixed_inds]
        free_dyn = false # If initial temperatures are given, dynamics aren't free.
    else
        init_temperatures = first.(values.(min_temperatures))
        min_init_temperatures = deepcopy(min_temperatures)
        max_init_temperatures = deepcopy(max_temperatures)
        free_dyn = free_dynamics
    end

    # Solve the initial temperatures via repeatedly solving the first up-to 24 hours
    # until the temperatures converge, starting from the permitted minimums.
    for i in 1:1000
        temps, hvac = solve_heating_demand_loop(
            archetype,
            indices[1:min(24, end)],
            delta_t,
            init_temperatures,
            min_init_temperatures,
            max_init_temperatures,
            external_load_vector,
            thermal_mass_vector,
            free_dyn,
        )
        if isapprox(last(temps), init_temperatures)
            return last(temps), min_temperatures, max_temperatures
        end
        init_temperatures = last(temps)
    end
    println("""
            No stable initial temperatures found for $(archetype)!
            Using minimum permitted temperatures instead.
            """)
    return deepcopy(min_temperatures), min_temperatures, max_temperatures
end


"""
    solve_heating_demand_loop(
        archetype::ArchetypeBuilding,
        indices::Vector{DateTime},
        delta_t::Int64,
        initial_temperatures::Vector{Float64},
        min_temperatures::Vector{SpineDataType},
        max_temperatures::Vector{SpineDataType},
        external_load_vector::Vector{Vector{Float64}},
        thermal_mass_vector::Vector{Float64},
        free_dynamics::Bool,
    )

Solve the heating/cooling demand one timestep at a time over the given indices.

Essentially, performs the following steps:
1. Initialize the temperature vector, HVAC demand vector, and a dictionary for the dynamic matrices for solving the problem.
2. Loop over the given `indices` and do the following:
    3. Invert the dynamics matrix using [`form_and_invert_dynamics_matrix`](@ref).
    4. Solve new temperatures if HVAC not in use.
    5. Check if new temperatures would violate temperature limits.
    6. If necessary, solve the HVAC demand via [`form_and_invert_hvac_matrix`](@ref) required to keep temperatures within set limits.
7. Return the solved temperatures and HVAC demand for each node and index.

See the [`solve_heating_demand`](@ref) function for the overall formulation.
"""
function solve_heating_demand_loop(
    archetype::ArchetypeBuilding,
    indices::Vector{DateTime},
    delta_t::Int64,
    initial_temperatures::Vector{Float64},
    min_temperatures::Vector{SpineDataType},
    max_temperatures::Vector{SpineDataType},
    external_load_vector::Vector{Vector{Float64}},
    thermal_mass_vector::Vector{Float64},
    free_dynamics::Bool,
)
    # Initialize the temperature vector, the HVAC heating/cooling demand vector,
    # and the heating/cooling demand solving matrix Dict
    len = length(initial_temperatures)
    temperatures = vcat(
        [initial_temperatures],
        repeat([zeros(len)], length(indices))
    )
    hvac_demand = repeat([zeros(len)], length(indices))

    # Loop over the indices, and solve the dynamics/HVAC demand.
    for (i, t) in enumerate(indices)
        # Calculate the new dynamics matrix and its inverse
        dynamics_matrix, inverted_dynamics_matrix =
            form_and_invert_dynamics_matrix(archetype, t, delta_t)

        # Calculate the new temperatures without HVAC.
        previous_temperature_effect_vector = thermal_mass_vector .* temperatures[i]
        new_temperatures =
            inverted_dynamics_matrix *
            (external_load_vector[i] + previous_temperature_effect_vector)

        # Check if the temperatures are within permissible limits.
        max_temp_vec = [
            parameter_value(max_temp)(t=t) for
            max_temp in max_temperatures
        ]
        min_temp_vec = [
            parameter_value(min_temp)(t=t) for
            min_temp in min_temperatures
        ]
        max_temp_check = new_temperatures .<= max_temp_vec
        min_temp_check = new_temperatures .>= min_temp_vec
        temp_check = max_temp_check .* min_temp_check
        if free_dynamics || all(temp_check)
            # If yes, simply save the new temperatures & zero demand, and move on.
            temperatures[i+1] = new_temperatures
            hvac_demand[i] = zeros(size(new_temperatures))
        else
            # Else, calculate the required HVAC demand.
            inverse_hvac_matrix =
                form_and_invert_hvac_matrix(dynamics_matrix, temp_check)

            # Find which nodes violate the temperature limits.
            fixed_max_temp_inds = findall(.!(max_temp_check))
            fixed_min_temp_inds = findall(.!(min_temp_check))

            # Solve the HVAC demand and new temperatures.
            # This is a bit complicated due to the violated temperatures
            # becoming fixed, moving them from the left to the right-hand side
            # of the system of equations.
            hvac_solution =
                inverse_hvac_matrix * (
                    external_load_vector[i] .+ previous_temperature_effect_vector .-
                    reduce(
                        .+,
                        dynamics_matrix[:, j] .* min_temp_vec[j] for
                        j in fixed_min_temp_inds;
                        init=0.0
                    ) .- reduce(
                        .+,
                        dynamics_matrix[:, j] .* max_temp_vec[j] for
                        j in fixed_max_temp_inds;
                        init=0.0
                    )
                )

            # Finally, separate the results into temperature and HVAC vectors.
            # Note that violated temperatures were fixed, and replaced with
            # the HVAC demand variables.
            new_temperatures = deepcopy(hvac_solution)
            new_temperatures[fixed_max_temp_inds] = max_temp_vec[fixed_max_temp_inds]
            new_temperatures[fixed_min_temp_inds] = min_temp_vec[fixed_min_temp_inds]
            hvac = zeros(size(hvac_solution))
            hvac[fixed_max_temp_inds] = hvac_solution[fixed_max_temp_inds]
            hvac[fixed_min_temp_inds] = hvac_solution[fixed_min_temp_inds]
            temperatures[i+1] = new_temperatures
            hvac_demand[i] = hvac
        end
    end
    # Remove initial temperature vector and return the rest
    popfirst!(temperatures)
    return temperatures, hvac_demand
end


"""
    form_and_invert_hvac_matrix(
        dynamics_matrix::Matrix{Float64},
        temp_check::BitVector,
    )

Forms and inverts the matrix for solving HVAC demand in different situations.

Essentially, this function performs the
```math
\\left( \\bm{A} - \\sum_{m \\in M}[\\bm{A}_{m} + \\bm{I}_{m}] \\right)^{-1}
```
transformation of the dynamics matrix `A`,
where the otherwise violated temperature variables `m ∈ M` are fixed
and replaced with a variable for the required heating/cooling demand.
See the [`solve_heating_demand`](@ref) function for the overall formulation.
"""
function form_and_invert_hvac_matrix(
    dynamics_matrix::Matrix{Float64},
    temp_check::BitVector,
)
    # HVAC matrix is based on the dynamics matrix,
    # except that all violated temperatures are fixed and their variables
    # are replaced with hvac demand.
    hvac_matrix = deepcopy(dynamics_matrix)
    for i in findall(.!(temp_check))
        hvac_matrix[:, i] .= 0.0
        hvac_matrix[i, i] = -1.0
    end
    return inv(hvac_matrix)
end


"""
    calculate_final_heating_demand(
        archetype::ArchetypeBuilding,
        temperatures_K::Dict{Object,SpineDataType},
        air_node::Object,
        free_nodes::Dict{Object,AbstractNode}
    )

Calculate the final heating and cooling demands of the interior air node.

Essentially, calculates the heating/cooling demand corrections for the preliminary
heating and cooling demands from ArBuWe.py based on the dynamic node temperatures
and their heat transfer coefficients.

Returns the final corrected `heating_demand_kW` and `cooling_demand_kW`,
as well as the `heating_correction_W` and `cooling_correction_W` for debug
purposes.
"""
function calculate_final_heating_demand(
    archetype::ArchetypeBuilding,
    temperatures_K::Dict{Object,T} where {T<:SpineDataType},
    air_node::Object,
    free_nodes::Dict{Object,AbstractNode},
)
    # Calculate the heating and cooling demand corrections from free nodes.
    # Set nodes already accounted for in `create_building_weather`.
    heating_correction_W = sum(
        abstract_node.heat_transfer_coefficients_W_K[air_node] *
        (archetype.weather_data.heating_set_point_K - temperatures_K[node]) for
        (node, abstract_node) in free_nodes
    )
    cooling_correction_W = sum(
        abstract_node.heat_transfer_coefficients_W_K[air_node] *
        (temperatures_K[node] - archetype.weather_data.cooling_set_point_K) for
        (node, abstract_node) in free_nodes
    )

    # Calculate the final heating and cooling demands.
    heating_demand_kW =
        timedata_operation(
            max,
            archetype.weather_data.preliminary_heating_demand_W + heating_correction_W,
            0.0,
        ) / 1e3
    cooling_demand_kW =
        timedata_operation(
            max,
            archetype.weather_data.preliminary_cooling_demand_W + cooling_correction_W,
            0.0,
        ) / 1e3
    return heating_demand_kW, cooling_demand_kW, heating_correction_W, cooling_correction_W
end