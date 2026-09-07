import Foundation

/// Typical emissivities, so setting one is a choice rather than a guess.
///
/// Treat these as starting points. Surface finish moves emissivity far more
/// than the material does — polished aluminium and the same aluminium
/// anodised are not remotely alike, which is why both are listed. Where a
/// range is normally published, the middle of it is used here.
///
/// The classic field trick still beats any table: stick a piece of matte
/// black tape on the shiny thing, let it settle, and measure the tape.
enum Materials {

    struct Entry {
        let name: String
        let emissivity: Double
    }

    /// Ordered roughly from "safe to assume" to "needs care", because the
    /// low-emissivity metals at the bottom are where readings go wrong.
    static let all: [Entry] = [
        Entry(name: "Skin, human", emissivity: 0.98),
        Entry(name: "Ice", emissivity: 0.97),
        Entry(name: "Water", emissivity: 0.96),
        Entry(name: "Tape, matte black", emissivity: 0.95),
        Entry(name: "Paint, matte", emissivity: 0.95),
        Entry(name: "Rubber", emissivity: 0.95),
        Entry(name: "Ceramic", emissivity: 0.95),
        Entry(name: "Fabric", emissivity: 0.95),
        Entry(name: "Asphalt", emissivity: 0.95),
        Entry(name: "Concrete", emissivity: 0.94),
        Entry(name: "Plastic, opaque", emissivity: 0.94),
        Entry(name: "Metal, painted", emissivity: 0.94),
        Entry(name: "Brick, common", emissivity: 0.93),
        Entry(name: "Paper", emissivity: 0.93),
        Entry(name: "Soil", emissivity: 0.93),
        Entry(name: "Glass", emissivity: 0.92),
        Entry(name: "Plaster", emissivity: 0.91),
        Entry(name: "Wood", emissivity: 0.90),
        Entry(name: "Steel, oxidised", emissivity: 0.80),
        Entry(name: "Aluminium, anodised", emissivity: 0.77),
        Entry(name: "Cast iron, oxidised", emissivity: 0.70),
        Entry(name: "Copper, oxidised", emissivity: 0.65),
        Entry(name: "Steel, galvanised", emissivity: 0.28),
        Entry(name: "Stainless steel, polished", emissivity: 0.17),
        Entry(name: "Aluminium, polished", emissivity: 0.05),
        Entry(name: "Copper, polished", emissivity: 0.04)
    ]
}
