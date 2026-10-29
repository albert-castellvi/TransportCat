# TransportCat

Native iOS client for the Barcelona metro in real time, built with SwiftUI.
Network topology and live arrivals come straight from the public TMB API
([developer.tmb.cat](https://developer.tmb.cat)); train positions are computed
on device by interpolating iBus arrivals over each line's geometry. No backend
of our own. Distributed via TestFlight through GitHub Actions (XcodeGen, no
committed `.xcodeproj`).
