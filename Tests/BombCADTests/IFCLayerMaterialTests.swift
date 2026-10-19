import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// A material layer named for its place in the wall ("Outer leaf") is read by what it is made of:
/// the converter's metadata gives the layer's own name only, so the material is found in the STEP
/// text (`IFCStep.layerMaterials`). No converter is needed.
@Suite("IFC layer materials")
struct IFCLayerMaterialTests {
    let step = Data(
        """
        ISO-10303-21;
        DATA;
        #1=IFCMATERIAL('Facing brick',$,$);
        #2=IFCMATERIAL('Mineral wool insulation',$,$);
        #3=IFCMATERIAL('Aggregate concrete block',$,$);
        #4=IFCMATERIALLAYER(#1,0.1025,$,'Outer leaf',$,$,$);
        #5=IFCMATERIALLAYER(#2,0.05,$,'Insulation',$,$,$);
        #6=IFCMATERIALLAYER(#3,0.1,$,'Inner leaf',$,$,$);
        #7=IFCMATERIALLAYERSET((#4,#5,#6),'Cavity wall',$);
        #8=IFCMATERIALLAYER(#3,0.215,$,'Inner leaf',$,$,$);
        #9=IFCMATERIALLAYERSET((#8),'Cavity wall',$);
        ENDSEC;
        END-ISO-10303-21;
        """.utf8)

    @Test("Each layer set's layers give their materials' names and thicknesses, in order")
    func layerSets() {
        let sets = IFCStep.layerMaterials(step)["Cavity wall"] ?? []
        #expect(sets.count == 2)
        #expect(
            sets.first?.map(\.material) == [
                "Facing brick", "Mineral wool insulation", "Aggregate concrete block",
            ])
        #expect(sets.first?.map(\.thickness) == [0.1025, 0.05, 0.1])
    }

    @Test("Layers are named by their material, the set of the same name with matching thicknesses chosen")
    func namedByMaterial() throws {
        let xml = Data(
            """
            <ifc xmlns:xlink="http://www.w3.org/1999/xlink">
              <units><IfcSIUnit UnitType="LENGTHUNIT" SI_equivalent="1"/></units>
              <materials>
                <IfcMaterialLayerSetUsage id="IfcMaterialLayerSetUsage_10" LayerSetName="Cavity wall">
                  <IfcMaterialLayer Name="Outer leaf" LayerThickness="0.1025"/>
                  <IfcMaterialLayer Name="Insulation" LayerThickness="0.05"/>
                  <IfcMaterialLayer Name="Inner leaf" LayerThickness="0.1"/>
                </IfcMaterialLayerSetUsage>
                <IfcMaterialLayerSetUsage id="IfcMaterialLayerSetUsage_11" LayerSetName="Cavity wall">
                  <IfcMaterialLayer Name="Inner leaf" LayerThickness="0.215"/>
                </IfcMaterialLayerSetUsage>
              </materials>
              <decomposition>
                <IfcWall id="0123456789012345678901">
                  <IfcMaterialLayerSetUsage xlink:href="#IfcMaterialLayerSetUsage_10"/>
                </IfcWall>
                <IfcWall id="1123456789012345678901">
                  <IfcMaterialLayerSetUsage xlink:href="#IfcMaterialLayerSetUsage_11"/>
                </IfcWall>
              </decomposition>
            </ifc>
            """.utf8)
        let named = try IFCMaterials.decode(xml, layerMaterials: IFCStep.layerMaterials(step))
        #expect(
            named["0123456789012345678901"]?.map(\.name)
                == ["Facing brick", "Mineral wool insulation", "Aggregate concrete block"])
        #expect(named["1123456789012345678901"]?.map(\.name) == ["Aggregate concrete block"])
        // Without the STEP text the layers keep their own names, as before.
        let plain = try IFCMaterials.decode(xml)
        #expect(plain["0123456789012345678901"]?.first?.name == "Outer leaf")
    }
}
