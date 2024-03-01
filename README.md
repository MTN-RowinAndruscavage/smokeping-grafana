# smokeping-grafana
Docker compose for smokeping-prober + prometheus + grafana

Added SuperQ's [smokeping_prober](https://github.com/SuperQ/smokeping_prober) to Michael Rodgers' prometheus + grafana [docker-compose](https://gitlab.com/mjrod/py-pg) stack.

This stack does 1 ping per second to configured IPv4 destinations and plots the results in a histogram and heatmap.

<img width="1702" alt="image" src="https://github.com/MTN-RowinAndruscavage/smokeping-grafana/assets/8740187/4c00166d-76da-4c7e-aa7c-a5b92f5abf4c">

## Configuration & Installation

You could  find and replace the CloudFlare `1.1.1.1` or Google DNS `8.8.8.8` GeoIP with something else if you like.

    docker compose up -d

You will still need to manually set up the prometheus data source in grafana at [localhost:3000](http://localhost:3000/) 
Go to Connections and add a prometheus data source at `http://prometheus:9090`

Your prometheus will have a randomly-generated uid, so you'll want to find and replace that into all instances of `"uid": "cbca6b21-2ffc-4ebd-9120-697a3132026e"` in the `grafana_smokeping_dashboard.json` file.
Then you'll need to load that into Dashboards | New | Import Dashboard .


## Limitations

smokeping_prober is configured to only sort the ping results into 0.005 ms buckets, so unfortunately you don't have the original latency data to do additional statistics on.

It also doesn't seem to keep track of dropped packets, so might need to do some query math from `smokeping_requests_total` to track those.
