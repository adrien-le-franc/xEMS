# developed with Julia 1.0.3
#
# EMS simulation server


using JSON, HTTP
using JLD
using StoOpt

### init battery parameters

const horizon = Int(10*60*24/15)
const dt = 15/60

const capacity = Ref(1.)
const power = Ref(0.)
const rc = Ref(0.95)
const rd = Ref(0.95)
const u_max = Ref(power.x*dt)

const states = Grid(0:0.05:1)
const state_steps = StoOpt.grid_steps(states)
const controls = Grid(-1:0.02:1)
const control_iterator = StoOpt.run(controls)

### init data selection

const path_to_data = Ref("")
const path_to_method = Ref("")
const site_id = Ref("")
const battery_id = Ref("")

const periods_data = Ref(Dict())
const period_prices = Ref(Price())
const offline_laws = Ref(Dict())

# note: improve by introducing vopt struct
const vopt = Ref(Dict())
const k = 10

const vopt_timer = Ref(Float64[])
const uopt_timer = Ref(Float64[])

### endpoints

function set_paths(request::HTTP.Request)
	j = HTTP.queryparams(HTTP.URI(request.target))
	path_to_data.x = j["data"]
	path_to_method.x = j["method"]
	include(path_to_method.x*"/method.jl")
	return HTTP.Response(200)
end

function update_site(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))
	site_id.x = j["site"]

	path_to_train_data = path_to_data.x*"/train/$(site_id.x).csv"
	offline_laws.x = compute_offline_laws(path_to_train_data)

	path_to_test_data = path_to_data.x*"/submit/$(site_id.x).csv"
	periods_data.x = load_test_periods(path_to_test_data)

	return HTTP.Response(200)

end

function update_battery(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))

	capacity.x = parse(Float64, string(j["capacity"])) / 1000
	power.x = parse(Float64, j["power"]) / 1000
	rc.x = parse(Float64, j["rc"])
	rd.x = parse(Float64, j["rd"])
	battery_id.x = j["id"]
	u_max.x = power.x*dt

	return HTTP.Response(200)

end

function update_period(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))
	period = j["period"]

	price_buy = periods_data.x[period]["buy"]
	price_sell = periods_data.x[period]["sell"]
	period_prices.x = Price(price_buy, price_sell)

	path_to_vopt = path_to_method.x*"/vopt/site_$(site_id.x)/battery_$(battery_id.x)"

	# if vopt exists -> use it !

	recycle_vopt, vopt.x = load_vopt(period, period_prices.x, periods_data.x, 
		path_to_vopt)

	if !recycle_vopt
		t0 = periods_data.x[period]["t0"]
		noise = compute_noise(t0, offline_laws.x)
		timer = @elapsed vopt.x = compute_value_functions(noise, controls, states, dynamics, 
			stage_cost, period_prices.x, horizon)
		path = path_to_vopt*"/period_$(period).jld"
		save(path, "vopt", vopt.x)
		push!(vopt_timer.x, timer)
	end

	return HTTP.Response(200)

end

function compute_soc(request::HTTP.Request)

	j = HTTP.queryparams(HTTP.URI(request.target))
	current_soc = [parse(Float64, j["current_soc"])]
	forecast_noise_15 = parse(Float64, j["forecast_noise_15"]) / 1000
	time_step = parse(Int64, j["time_step"])
	prices = period_prices.x[time_step]

	timer = @elapsed uopt = compute_online_policy(current_soc, [forecast_noise_15], prices, 
		states, control_iterator, vopt.x[time_step], dynamics, stage_cost, state_steps)

	next_soc = dynamics(current_soc, uopt, 0.)
	if time_step % 5 == 0
		push!(uopt_timer.x, timer)
	end

	return HTTP.Response(200, JSON.json(Float64(next_soc...)))
end 

function finish(request::HTTP.Request)
	path = path_to_method.x*"/timer.jld"
	save(path, "vopt", vopt_timer.x, "uopt", uopt_timer.x)
	# close server ?
	return HTTP.Response(200)
end

### make a router and add routes for endpoints

const router = HTTP.Router()
HTTP.@register(router, "GET", "/set_paths", set_paths)
HTTP.@register(router, "GET", "/update_site", update_site)
HTTP.@register(router, "GET", "/update_battery", update_battery)
HTTP.@register(router, "GET", "/update_period", update_period)
HTTP.@register(router, "GET", "/compute_soc", compute_soc)
HTTP.@register(router, "GET", "/finish", finish)

### create and run server

HTTP.serve(router, "0.0.0.0", 8000; verbose=true)